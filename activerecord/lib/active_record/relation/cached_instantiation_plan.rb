# frozen_string_literal: true

module ActiveRecord
  class Relation
    # Pre-computed metadata for fast record instantiation on query shape cache hits.
    #
    # When a query shape is cached, the result set's column layout is identical
    # on every execution. This plan captures per-shape metadata that would
    # otherwise be recomputed for every row:
    #
    #   - additional_types: column types from the adapter that aren't already
    #     known by the model's attribute_types (computed once, not per row)
    #   - has_sti: whether the result includes the inheritance_column
    #   - skip_callbacks: whether after_find and after_initialize chains are empty
    #   - model_types: reference to the model's frozen attribute_types hash
    #   - default_attributes: the model's default attribute values for AttributeSet
    #
    # The plan is immutable once created and safe to share across threads.
    class CachedInstantiationPlan # :nodoc:
      attr_reader :model_class,
                  :additional_types,
                  :has_sti,
                  :skip_callbacks,
                  :model_types,
                  :default_attributes

      def initialize(model_class, result_column_types)
        @model_class = model_class

        # Pre-compute additional_types: adapter-reported types for columns not
        # already in the model's attribute_types. Normally done per-query in
        # _load_from_sql.
        model_attr_types = model_class.attribute_types
        if result_column_types.empty?
          @additional_types = {}.freeze
        else
          filtered = result_column_types.reject { |k, _| model_attr_types.key?(k) }
          @additional_types = filtered.freeze
        end

        # Pre-compute STI check
        @has_sti = model_class._has_attribute?(model_class.inheritance_column)

        # Pre-compute callback emptiness. When empty, we skip _run_find_callbacks
        # and _run_initialize_callbacks entirely.
        @skip_callbacks = model_class._find_callbacks.empty? &&
                          model_class._initialize_callbacks.empty?

        # Cache references to avoid repeated lookups per row
        @model_types = model_attr_types
        @default_attributes = model_class.attributes_builder.default_attributes

        freeze
      end

      # Instantiate records from a Result using pre-computed metadata.
      # This is the fast path that replaces _load_from_sql on cache hits.
      def instantiate_records(result_set, &block)
        return [].freeze if result_set.empty?

        indexed_rows = result_set.indexed_rows
        additional = @additional_types
        model_types = @model_types
        defaults = @default_attributes

        message_bus = ActiveSupport::Notifications.instrumenter
        payload = { record_count: indexed_rows.size, class_name: @model_class.name }

        message_bus.instrument("instantiation.active_record", payload) do
          if @has_sti && result_set.includes_column?(@model_class.inheritance_column)
            instantiate_with_sti(indexed_rows, additional, model_types, defaults, &block)
          else
            instantiate_homogeneous(indexed_rows, additional, model_types, defaults, &block)
          end
        end
      end

      private
        # Fast path for homogeneous result sets (no STI).
        # Inlines all instance variable setup to avoid method dispatch per row.
        def instantiate_homogeneous(indexed_rows, additional, model_types, defaults, &block)
          klass = @model_class
          skip_cbs = @skip_callbacks

          # Ensure attribute methods are defined once, not per row
          klass.define_attribute_methods

          # Pre-fetch class-level values once
          pk = klass.primary_key
          strict_loading_default = klass.strict_loading_by_default
          strict_loading_mode = klass.strict_loading_mode

          indexed_rows.map do |values|
            attributes = ActiveModel::LazyAttributeSet.new(values, model_types, additional, defaults)

            record = klass.allocate
            record.instance_variable_set(:@new_record, false)
            record.instance_variable_set(:@attributes, attributes)
            record.instance_variable_set(:@readonly, false)
            record.instance_variable_set(:@previously_new_record, false)
            record.instance_variable_set(:@destroyed, false)
            record.instance_variable_set(:@marked_for_destruction, false)
            record.instance_variable_set(:@destroyed_by_association, nil)
            record.instance_variable_set(:@_start_transaction_state, nil)
            record.instance_variable_set(:@primary_key, pk)
            record.instance_variable_set(:@strict_loading, strict_loading_default)
            record.instance_variable_set(:@strict_loading_mode, strict_loading_mode)

            if block
              yield record
            end

            unless skip_cbs
              record.send(:_run_find_callbacks)
              record.send(:_run_initialize_callbacks)
            end

            record
          end.freeze
        end

        # STI path — must discriminate class per row.
        def instantiate_with_sti(indexed_rows, additional, model_types, defaults, &block)
          base_klass = @model_class
          inheritance_column = base_klass.inheritance_column

          # Cache per-subclass metadata to avoid repeated lookups
          subclass_skip_callbacks = {}
          subclass_metadata = {}

          indexed_rows.map do |values|
            # Determine the correct class for this row
            type_value = values[inheritance_column]

            klass = if type_value.present?
              base_klass.send(:find_sti_class, type_value)
            else
              base_klass
            end

            # Get or compute per-class metadata
            meta = subclass_metadata.fetch(klass) do
              if klass == base_klass
                m = { types: model_types, defaults: defaults, additional: additional }
              else
                kt = klass.attribute_types
                kd = klass.attributes_builder.default_attributes
                ka = additional.empty? ? additional : additional.reject { |k, _| kt.key?(k) }.freeze
                m = { types: kt, defaults: kd, additional: ka }
              end
              m[:pk] = klass.primary_key
              m[:strict_loading] = klass.strict_loading_by_default
              m[:strict_loading_mode] = klass.strict_loading_mode
              klass.define_attribute_methods
              subclass_metadata[klass] = m
            end

            attributes = ActiveModel::LazyAttributeSet.new(
              values, meta[:types], meta[:additional], meta[:defaults]
            )

            record = klass.allocate
            record.instance_variable_set(:@new_record, false)
            record.instance_variable_set(:@attributes, attributes)
            record.instance_variable_set(:@readonly, false)
            record.instance_variable_set(:@previously_new_record, false)
            record.instance_variable_set(:@destroyed, false)
            record.instance_variable_set(:@marked_for_destruction, false)
            record.instance_variable_set(:@destroyed_by_association, nil)
            record.instance_variable_set(:@_start_transaction_state, nil)
            record.instance_variable_set(:@primary_key, meta[:pk])
            record.instance_variable_set(:@strict_loading, meta[:strict_loading])
            record.instance_variable_set(:@strict_loading_mode, meta[:strict_loading_mode])

            if block
              yield record
            end

            skip_cbs = subclass_skip_callbacks.fetch(klass) do
              subclass_skip_callbacks[klass] = klass._find_callbacks.empty? &&
                                               klass._initialize_callbacks.empty?
            end

            unless skip_cbs
              record.send(:_run_find_callbacks)
              record.send(:_run_initialize_callbacks)
            end

            record
          end.freeze
        end
    end
  end
end
