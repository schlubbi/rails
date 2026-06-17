# frozen_string_literal: true

require "concurrent/map"

module ActiveRecord
  # Caches the compiled SQL template for query shapes that have been seen before.
  #
  # A "query shape" is the structural identity of a query — everything except
  # the bind values. Two queries with the same shape produce identical SQL
  # templates and differ only in their bind parameters.
  #
  # On a cache hit, this skips build_arel and the visitor walk entirely,
  # going straight from the Relation's @values to select_all with the
  # cached SQL template and freshly-extracted bind values.
  #
  # This is an internal optimization. It is not part of the public API.
  class QueryShapeCache # :nodoc:
    # Features that make a query non-cacheable.
    NON_CACHEABLE_KEYS = Set.new(%i[
      joins left_outer_joins includes eager_load preload
      from having lock with group
      references extending unscope
      optimizer_hints annotate
      create_with skip_query_cache
    ]).freeze

    CachedShape = Struct.new(:sql, :preparable, :retryable, keyword_init: true) # :nodoc:

    def initialize
      @cache = Concurrent::Map.new
    end

    def clear!
      @cache.clear
    end

    def size
      @cache.size
    end

    # Look up a cached SQL template for this relation's shape.
    # Returns [CachedShape, binds] on hit, nil on miss or non-cacheable.
    def lookup(relation)
      key = shape_key(relation)
      return nil unless key

      if (entry = @cache[key])
        binds = extract_binds(relation)
        [entry, binds]
      end
    end

    # Record a compiled SQL template for this relation's shape.
    # Called after the first execution of a cacheable shape.
    def record(relation, sql, preparable, retryable)
      key = shape_key(relation)
      return unless key

      @cache.compute_if_absent(key) do
        CachedShape.new(sql: sql.freeze, preparable: preparable, retryable: retryable)
      end
    end

    # Compute the shape key for a relation.
    # Returns nil if the query is not cacheable.
    def shape_key(relation)
      values = relation.send(:values)

      # Quick bail: any non-cacheable feature present?
      NON_CACHEABLE_KEYS.each do |k|
        val = values[k]
        if val
          return nil if val.is_a?(Array) ? !val.empty? : true
        end
      end

      key = []

      # Where clause shape
      wc = values[:where]
      if wc && !wc.empty?
        ws = where_clause_shape(wc)
        return nil unless ws
        key << ws
      end

      # Order shape
      order = values[:order]
      if order && !order.empty?
        os = order_shape(order)
        return nil unless os
        key << os
      end

      # Select shape
      select = values[:select]
      if select && !select.empty?
        ss = select_shape(select)
        return nil unless ss
        key << ss
      end

      key << (values[:limit] ? :L : nil)
      key << (values[:offset] ? :O : nil)
      key << (values[:distinct] ? :D : nil)
      key << (values[:reverse_order] ? :R : nil)
      key.compact!

      key
    end

    # Extract bind values from the relation's built WhereClause predicates
    # and limit/offset values. These are already Arel-typed from the
    # PredicateBuilder, so they can be passed directly to select_all.
    def extract_binds(relation)
      values = relation.send(:values)
      binds = []

      wc = values[:where]
      if wc && !wc.empty?
        extract_where_binds(wc, binds)
      end

      if values[:limit]
        binds << ActiveModel::Attribute.with_cast_value("LIMIT", values[:limit], Type.default_value)
      end

      if values[:offset]
        binds << ActiveModel::Attribute.with_cast_value("OFFSET", values[:offset].to_i, Type.default_value)
      end

      binds
    end

    private
      def where_clause_shape(wc)
        predicates = wc.send(:predicates)
        parts = Array.new(predicates.size)

        predicates.each_with_index do |pred, i|
          part = predicate_shape(pred)
          return nil unless part
          parts[i] = part
        end

        parts.sort!
        parts
      end

      def predicate_shape(pred)
        case pred
        when Arel::Nodes::Equality
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:eq, left.name.to_s]
        when Arel::Nodes::HomogeneousIn
          attr = pred.attribute
          return nil unless attr.respond_to?(:name)
          [:hin, attr.name.to_s, pred.values.size]
        when Arel::Nodes::In
          left = pred.left
          return nil unless left.respond_to?(:name)
          right = pred.right
          return nil unless right.is_a?(Array)
          [:in, left.name.to_s, right.size]
        when Arel::Nodes::NotEqual
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:neq, left.name.to_s]
        when Arel::Nodes::GreaterThan
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:gt, left.name.to_s]
        when Arel::Nodes::GreaterThanOrEqual
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:gte, left.name.to_s]
        when Arel::Nodes::LessThan
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:lt, left.name.to_s]
        when Arel::Nodes::LessThanOrEqual
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:lte, left.name.to_s]
        when Arel::Nodes::Between
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:between, left.name.to_s]
        when Arel::Nodes::IsNotDistinctFrom
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:indistinct, left.name.to_s]
        when Arel::Nodes::IsDistinctFrom
          left = pred.left
          return nil unless left.respond_to?(:name)
          [:distinct_from, left.name.to_s]
        else
          nil # String SQL, Arel::Nodes::Or, subqueries, etc.
        end
      end

      def order_shape(order_values)
        parts = Array.new(order_values.size)
        order_values.each_with_index do |o, i|
          case o
          when Arel::Nodes::Ascending
            name = extract_column_name(o.expr)
            return nil unless name
            parts[i] = [:asc, name]
          when Arel::Nodes::Descending
            name = extract_column_name(o.expr)
            return nil unless name
            parts[i] = [:desc, name]
          when Symbol
            parts[i] = [:asc, o.to_s]
          else
            return nil # Raw SQL, complex Arel — not cacheable
          end
        end
        parts
      end

      def extract_column_name(expr)
        if expr.respond_to?(:name)
          expr.name.to_s
        elsif expr.is_a?(String)
          # SqlLiteral like '"created_at"' — extract the column name
          expr.delete('"').delete('`').strip
        end
      end

      def select_shape(select_values)
        parts = Array.new(select_values.size)
        select_values.each_with_index do |s, i|
          case s
          when Symbol then parts[i] = s.to_s
          when String then parts[i] = s
          else return nil
          end
        end
        parts.sort!
        parts
      end

      def extract_where_binds(wc, binds)
        wc.send(:predicates).each do |pred|
          case pred
          when Arel::Nodes::Equality
            binds << pred.right
          when Arel::Nodes::HomogeneousIn
            binds.concat(pred.values)
          when Arel::Nodes::In
            binds.concat(Array(pred.right))
          when Arel::Nodes::NotEqual
            binds << pred.right
          when Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual,
               Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual
            binds << pred.right
          when Arel::Nodes::Between
            range = pred.right
            binds << range.left << range.right
          when Arel::Nodes::IsNotDistinctFrom, Arel::Nodes::IsDistinctFrom
            binds << pred.right
          end
        end
      end
  end
end
