# frozen_string_literal: true

module ActiveRecord
  # = Fast Query
  #
  # Declares a class method that executes a pre-compiled query with fast
  # model hydration. The SQL is built once at first call, cached, and
  # reused for subsequent calls -- skipping the Relation/Arel pipeline
  # entirely. Returned instances are readonly.
  #
  #   class Post < ActiveRecord::Base
  #     fast_query :published_recent, ->(limit: 10) {
  #       where(status: "published").order(published_at: :desc).limit(limit)
  #     }
  #   end
  #
  #   posts = Post.published_recent(limit: 5)
  #   posts.first.title      # => "Hello"
  #   posts.first.readonly?  # => true
  #
  # == What it skips
  #
  # Compared to a normal +where(...).to_a+, fast_query skips:
  #
  # - Relation creation and cloning (no +spawn+, no +@values.dup+)
  # - Arel AST construction and visitor walk
  # - +init_internals+ chain (no dirty tracking, no empty hash allocation)
  # - +after_find+ / +after_initialize+ callbacks
  #
  # == What it keeps
  #
  # - Real model instances (+is_a?(Post)+ returns true)
  # - Attribute access with lazy type casting
  # - Association loading (triggers normal AR lazy load on first access)
  # - +readonly?+ returns true
  # - STI discrimination (correct subclass instantiated)
  #
  # == Limitations
  #
  # - Returned instances are readonly -- no +save+, +update+, or +destroy+
  # - No +after_find+ / +after_initialize+ callbacks fire
  # - No dirty tracking (+changed?+ always returns false)
  # - Returns a frozen Array, not a Relation (no further chaining)
  # - Parameters must be simple scalar values (no nil, Array, Range, Hash)
  #
  module FastQuery
    extend ActiveSupport::Concern

    class CompiledQuery # :nodoc:
      # Sentinel values used to detect bind positions via two-pass diff.
      # Chosen to be unlikely to appear in real SQL or collide with each other.
      SENTINEL_A = { Integer => 715_827_882, Float => 715827882.5,
                     String => "__fq_sentinel_a_7158__", Symbol => :__fq_sentinel_a__ }.freeze

      def initialize(model, callable)
        @model = model
        @callable = callable
        @lock = Mutex.new
        @compiled = nil
      end

      def execute(kwargs)
        @model.with_connection do |connection|
          compiled = @compiled || @lock.synchronize do
            @compiled ||= compile(connection, kwargs)
          end

          # Build SQL by substituting quoted bind values into the template
          quoted_values = compiled[:bind_names].map do |name|
            connection.quote(compiled[:bind_types][name].serialize(kwargs[name]))
          end

          sql = compiled[:sql_template] % quoted_values
          result = connection.select_all(sql, "#{@model.name} Fast", [], allow_retry: true)
          fast_load(result)
        end
      end

      private

      def compile(connection, sample_kwargs)
        return compile_static(connection, sample_kwargs) if sample_kwargs.empty?

        # Detect the Ruby type of each parameter for sentinel selection
        param_types = sample_kwargs.transform_values { |v| sentinel_type(v) }

        # Build SQL with sentinel values that won't appear in real SQL
        sentinel_kwargs = sample_kwargs.each_with_object({}) do |(name, _), h|
          h[name] = SENTINEL_A[param_types[name]]
        end

        sql = build_sql(connection, sentinel_kwargs)

        # Find each quoted sentinel in the SQL and replace with %s
        bind_names = []
        bind_types = {}
        template = sql.dup

        # Process params in the order they appear in the SQL
        replacements = sentinel_kwargs.map do |name, sentinel_value|
          type = @model.attribute_types[name.to_s] || ActiveModel::Type::Value.new
          quoted = connection.quote(type.serialize(sentinel_value))
          pos = template.index(quoted)
          [name, type, quoted, pos]
        end.select { |_, _, _, pos| pos }.sort_by(&:last)

        # Replace from right to left so positions stay valid
        replacements.reverse_each do |name, type, quoted, _|
          pos = template.index(quoted)
          template[pos, quoted.length] = "%s"
          bind_names.unshift(name)
          bind_types[name] = type
        end

        template.freeze

        { sql_template: template, bind_names: bind_names.freeze,
          bind_types: bind_types.freeze }
      end

      def compile_static(connection, sample_kwargs)
        sql = build_sql(connection, sample_kwargs)
        { sql_template: sql.freeze, bind_names: [].freeze,
          bind_types: {}.freeze }
      end

      def build_sql(connection, kwargs)
        relation = @callable.call(**kwargs)
        connection.unprepared_statement { connection.to_sql(relation.arel) }
      end

      def sentinel_type(value)
        case value
        when Integer then Integer
        when Float then Float
        when String then String
        when Symbol then Symbol
        else Integer # default — most bind values are integers
        end
      end

      def fast_load(result)
        return EMPTY_ARRAY if result.empty?

        model = @model
        builder = model.attributes_builder
        column_types = result.column_types
        unless column_types.empty?
          column_types = column_types.reject { |k, _| model.attribute_types.key?(k) }
        end

        has_inheritance = result.includes_column?(model.inheritance_column)

        if has_inheritance
          sti_cache = {}
          builder_cache = {}
          result.indexed_rows.map do |record|
            type_value = record[model.inheritance_column]
            klass = (sti_cache[type_value] ||= model.send(:discriminate_class_for_record, record))
            b = (builder_cache[klass] ||= klass.attributes_builder)
            fast_instantiate(klass, b, record, column_types)
          end.freeze
        else
          result.indexed_rows.map do |record|
            fast_instantiate(model, builder, record, column_types)
          end.freeze
        end
      end

      def fast_instantiate(klass, builder, record, column_types)
        attributes = builder.build_from_database(record, column_types)
        instance = klass.allocate

        # Minimal init — skip the full init_internals super chain.
        # Sets only the ivars that attribute access and association loading need.
        instance.instance_variable_set(:@new_record, false)
        instance.instance_variable_set(:@attributes, attributes)
        instance.instance_variable_set(:@readonly, true)
        instance.instance_variable_set(:@destroyed, false)
        instance.instance_variable_set(:@marked_for_destruction, false)
        instance.instance_variable_set(:@primary_key, klass.primary_key)
        instance.instance_variable_set(:@strict_loading, false)
        instance.instance_variable_set(:@strict_loading_mode, :all)
        instance.instance_variable_set(:@association_cache, EMPTY_HASH)
        instance.instance_variable_set(:@aggregation_cache, EMPTY_HASH)

        instance
      end

      EMPTY_HASH = {}.freeze
      EMPTY_ARRAY = [].freeze
      private_constant :EMPTY_HASH, :EMPTY_ARRAY
    end

    class_methods do
      # Declares a fast, pre-compiled query method on the model class.
      #
      # The block receives keyword arguments and must return a Relation.
      # The SQL is compiled from the Relation on first call, then reused.
      #
      #   class Post < ActiveRecord::Base
      #     fast_query :active_by_owner, ->(owner_id:) {
      #       where(owner_id: owner_id, active: true).order(:id)
      #     }
      #   end
      #
      #   posts = Post.active_by_owner(owner_id: 42)
      #
      def fast_query(name, callable = nil, &block)
        callable ||= block
        compiled = CompiledQuery.new(self, callable)

        define_singleton_method(name) do |**kwargs|
          compiled.execute(kwargs)
        end
      end
    end
  end
end
