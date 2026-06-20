# frozen_string_literal: true

module ActiveRecord
  class Relation
    module QueryShapeCache # :nodoc:
      private

        # Check cache and return [sql, retryable, cached_shape] or nil.
        def find_cached_query_shape(connection)
          return unless cacheable_query_shape?

          key = query_shape_key
          return unless key

          cached = model.query_shape_cache.get(key)
          return unless cached

          binds = if @raw_where_hashes.is_a?(Array)
            extract_binds_from_raw_hashes(cached.bind_map)
          else
            extract_shape_binds(cached.bind_map)
          end

          sql = cached.query_builder.sql_for(binds, connection)
          [sql, cached.query_builder.retryable, cached]
        end

        # After a cache miss, compile via the shape-aware collector and store.
        def cache_query_shape!(connection, arel_ast)
          return unless cacheable_query_shape?

          key = query_shape_key
          return unless key
          return if model.query_shape_cache.get(key) # another thread may have populated

          collector = ShapeAwareCollector.new
          collector.retryable = true
          parts, binds = connection.visitor.compile(arel_ast, collector)
          query_builder = StatementCache.partial_query(parts, retryable: collector.retryable)

          bind_map = build_bind_map_from_binds(binds)
          return unless bind_map

          cached = CachedQueryShape.new(query_builder, bind_map)
          model.query_shape_cache.set(key, cached)
        end

        # Returns true if this relation's query shape can be cached.
        def cacheable_query_shape?
          return false if eager_loading?
          return false if from_clause.present?
          return false unless joins_values.empty?
          return false unless left_outer_joins_values.empty?
          return false unless includes_values.empty?
          return false if @values.key?(:having)
          return false if @values.key?(:with)
          return false if @values.key?(:optimizer_hints)
          return false if @values.key?(:annotate)
          return false if where_clause.predicates.any? { |p| or_predicate?(p) }

          true
        end

        # Compute a shape fingerprint from @values structure.
        # Returns nil if any component is uncacheable.
        def query_shape_key
          parts = []
          parts << model.object_id

          where_clause.predicates.each do |pred|
            shape = predicate_shape(pred)
            return nil unless shape
            parts << shape
          end

          if order_values.any?
            order_values.each do |o|
              shape = order_shape(o)
              return nil unless shape
              parts << shape
            end
          end

          parts << :limit if limit_value
          parts << :offset if offset_value
          parts << :distinct if distinct_value
          parts << [:lock, lock_value] if lock_value

          if select_values.any?
            select_shapes = select_values.map { |s| select_shape(s) }
            return nil if select_shapes.any?(&:nil?)
            parts << [:select, select_shapes]
          end

          if group_values.any?
            group_shapes = group_values.map { |g| group_shape(g) }
            return nil if group_shapes.any?(&:nil?)
            parts << [:group, group_shapes]
          end

          parts.hash
        end

        # --- Predicate shape helpers ---

        def predicate_shape(pred)
          case pred
          when Arel::Nodes::Equality
            if pred.left.respond_to?(:name)
              if pred.right.nil?
                [:eq_null, pred.left.name]
              elsif unboundable_value?(pred.right)
                [:eq_unbound, pred.left.name]
              elsif bindable_value?(pred.right)
                [:eq, pred.left.name]
              end
            end
          when Arel::Nodes::NotEqual
            if pred.left.respond_to?(:name)
              if pred.right.nil?
                [:neq_null, pred.left.name]
              elsif bindable_value?(pred.right)
                [:neq, pred.left.name]
              end
            end
          when Arel::Nodes::HomogeneousIn
            [:in, pred.attribute.name, pred.type]
          when Arel::Nodes::Between
            if pred.left.respond_to?(:name) && between_bounds_bindable?(pred.right)
              [:between, pred.left.name]
            end
          when Arel::Nodes::GreaterThan
            [:gt, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::GreaterThanOrEqual
            [:gteq, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::LessThan
            [:lt, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::LessThanOrEqual
            [:lteq, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::IsNotDistinctFrom
            [:indist, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::IsDistinctFrom
            [:dist, pred.left.name] if comparison_cacheable?(pred)
          when Arel::Nodes::Grouping
            inner = predicate_shape(pred.expr)
            inner ? [:group, inner] : nil
          else
            nil
          end
        end

        # A comparison predicate is cacheable only when its right-hand value
        # renders as a SQL bind placeholder (BindParam or Attribute), not an
        # inline literal (e.g. Arel::Nodes::Casted from raw Arel comparisons).
        def comparison_cacheable?(pred)
          pred.left.respond_to?(:name) &&
            (unboundable_value?(pred.right) || bindable_value?(pred.right))
        end

        def between_bounds_bindable?(and_node)
          and_node.is_a?(Arel::Nodes::And) &&
            bindable_value?(and_node.left) && bindable_value?(and_node.right)
        end

        # True if a predicate's value node renders as a SQL bind placeholder
        # rather than being inlined into compiled SQL. Inline literals such as
        # Arel::Nodes::Casted are NOT bindable.
        def bindable_value?(node)
          node.is_a?(Arel::Nodes::BindParam) || node.is_a?(ActiveModel::Attribute)
        end

        def or_predicate?(pred)
          case pred
          when Arel::Nodes::Or
            true
          when Arel::Nodes::Grouping
            or_predicate?(pred.expr)
          else
            false
          end
        end

        def unboundable_value?(value)
          value.respond_to?(:unboundable?) && value.unboundable?
        end

        def order_shape(order)
          case order
          when Arel::Nodes::Ascending
            expr = order.expr
            expr.respond_to?(:name) ? [:asc, expr.name] : nil
          when Arel::Nodes::Descending
            expr = order.expr
            expr.respond_to?(:name) ? [:desc, expr.name] : nil
          else
            nil
          end
        end

        def select_shape(sel)
          case sel
          when Arel::Attributes::Attribute
            sel.name
          when Symbol
            sel.to_s
          else
            nil
          end
        end

        def group_shape(grp)
          case grp
          when Arel::Attributes::Attribute
            grp.name
          when Symbol
            grp.to_s
          else
            nil
          end
        end

        # --- Phase 2: Fast bind extraction from raw where hashes ---

        # Extract binds from the tracked raw where hashes instead of
        # walking Arel predicate nodes. Faster because it avoids
        # QueryAttribute and Arel node traversal.
        #
        # Falls back to the Arel-based extract_shape_binds when raw values
        # don't match the expected predicate shape (single-element arrays
        # collapsed to scalars, implicit STI predicates, etc.).
        def extract_binds_from_raw_hashes(bind_map)
          binds = []
          attr_types = model.attribute_types

          # Build a flat list of (column, value) from raw hashes
          # in the same order predicates were built
          raw_pairs = []
          @raw_where_hashes.each do |hash|
            hash.each { |col, val| raw_pairs << [col, val] }
          end

          # If the number of raw pairs doesn't match the predicate count,
          # there are implicit predicates (STI type, default scopes) that
          # aren't in any where-hash. Fall back to the Arel path.
          preds = where_clause.predicates
          if raw_pairs.size != preds.size
            return extract_shape_binds(bind_map)
          end

          bind_map.each do |desc|
            case desc[:source]
            when :predicate
              col, val = raw_pairs[desc[:index]]
              # Verify column matches the predicate; fall back if not.
              pred_col = predicate_column_name(preds[desc[:index]])
              if pred_col && col.to_s != pred_col
                return extract_shape_binds(bind_map)
              end

              type = attr_types[col]

              case desc[:extractor]
              when :array
                return extract_shape_binds(bind_map) unless val.is_a?(Array) || val.is_a?(Set)
                # Rails flattens nested arrays, drops nils, dedups before
                # building HomogeneousIn. Read the already-normalized values
                # off the predicate (source of truth) instead of re-casting.
                pred = preds[desc[:index]]
                return extract_shape_binds(bind_map) unless pred.respond_to?(:casted_values)
                binds << pred.casted_values
              when :between_left
                return extract_shape_binds(bind_map) unless val.is_a?(Range)
                binds << cast_bind_value(type, val.begin)
              when :between_right
                return extract_shape_binds(bind_map) unless val.is_a?(Range)
                binds << cast_bind_value(type, val.end)
              when :scalar
                # Rails collapses single-element arrays/Sets to scalar =.
                # Validate shape, but read the bind from the predicate (not
                # the raw value) to handle association FK objects, etc.
                if val.is_a?(Array) || val.is_a?(Set)
                  arr = val.is_a?(Set) ? val.to_a : val
                  return extract_shape_binds(bind_map) unless arr.size == 1
                elsif val.is_a?(Range)
                  return extract_shape_binds(bind_map)
                end
                binds << extract_scalar_bind(preds[desc[:index]], desc)
              when :none
                # Predicate emits no bind (IS NULL, unboundable) — skip.
                next
              end
            when :limit
              binds << limit_value
            when :offset
              binds << offset_value.to_i
            end
          end
          binds
        end

        # Type-cast a raw Ruby value into a database-ready form.
        def cast_bind_value(type, value)
          if type
            type.serialize(type.cast(value))
          else
            value
          end
        end

        # Extract the column name from a predicate node.
        def predicate_column_name(pred)
          case pred
          when Arel::Nodes::Equality, Arel::Nodes::NotEqual,
               Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual,
               Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual,
               Arel::Nodes::IsNotDistinctFrom, Arel::Nodes::IsDistinctFrom,
               Arel::Nodes::Between
            pred.left.respond_to?(:name) ? pred.left.name.to_s : nil
          when Arel::Nodes::HomogeneousIn
            pred.attribute.respond_to?(:name) ? pred.attribute.name.to_s : nil
          when Arel::Nodes::Grouping
            predicate_column_name(pred.expr)
          else
            nil
          end
        end

        # --- Phase 1: Bind extraction from Arel predicates ---

        def extract_shape_binds(bind_map)
          binds = []
          preds = where_clause.predicates

          bind_map.each do |desc|
            case desc[:source]
            when :predicate
              next if desc[:extractor] == :none
              pred = preds[desc[:index]]
              if desc[:extractor] == :array
                binds << pred.casted_values
              else
                binds << extract_scalar_bind(pred, desc)
              end
            when :limit
              binds << limit_value
            when :offset
              binds << offset_value.to_i
            end
          end
          binds
        end

        def extract_scalar_bind(pred, desc)
          case pred
          when Arel::Nodes::Equality, Arel::Nodes::NotEqual,
               Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual,
               Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual,
               Arel::Nodes::IsNotDistinctFrom, Arel::Nodes::IsDistinctFrom
            pred.right
          when Arel::Nodes::Between
            and_node = pred.right
            case desc[:extractor]
            when :between_left
              and_node.left
            when :between_right
              and_node.right
            end
          when Arel::Nodes::Grouping
            extract_scalar_bind(pred.expr, desc)
          end
        end

        # --- Bind map building ---
        #
        # Predicate-driven: walks predicates to determine how many binds each
        # contributes (0 for IS NULL/unboundable, 1 for scalar, 2 for BETWEEN,
        # 1 array for HomogeneousIn). Then appends LIMIT/OFFSET from trailing
        # binds. Returns nil if the derived count doesn't match actual binds.

        def build_bind_map_from_binds(binds)
          bind_map = []
          preds = where_clause.predicates
          expected_bind_count = 0

          # Phase 1: Walk predicates to build the map
          preds.each_with_index do |pred, pred_index|
            entries = predicate_bind_entries(pred, pred_index)
            return nil unless entries # uncacheable predicate
            entries.each do |entry|
              bind_map << entry
              expected_bind_count += 1 unless entry[:extractor] == :none
            end
          end

          # Phase 2: Append LIMIT / OFFSET from the trailing binds
          bind_tail_start = expected_bind_count
          binds[bind_tail_start..].each do |bind|
            if bind.respond_to?(:name)
              case bind.name
              when "LIMIT"
                bind_map << { source: :limit }
              when "OFFSET"
                bind_map << { source: :offset }
              else
                return nil # unknown trailing bind
              end
            else
              return nil # unexpected trailing bind
            end
          end

          bind_map
        end

        # Returns an array of bind map entries for a single predicate,
        # or nil if the predicate is uncacheable.
        #
        # Only predicates with bindable values (BindParam / Attribute) emit
        # bind entries. Inline literals (Arel::Nodes::Casted) bake a varying
        # value into compiled SQL and cannot be replayed for a different value,
        # so we refuse to cache them (return nil).
        def predicate_bind_entries(pred, pred_index)
          case pred
          when Arel::Nodes::Equality, Arel::Nodes::NotEqual,
               Arel::Nodes::IsNotDistinctFrom, Arel::Nodes::IsDistinctFrom
            if pred.right.nil? || unboundable_value?(pred.right)
              # IS NULL / IS NOT NULL / unboundable — emits zero binds
              [{ source: :predicate, index: pred_index, extractor: :none }]
            elsif bindable_value?(pred.right)
              [{ source: :predicate, index: pred_index, extractor: :scalar }]
            else
              nil # inline literal (Casted) — not cacheable
            end
          when Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual,
               Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual
            if unboundable_value?(pred.right)
              []
            elsif bindable_value?(pred.right)
              [{ source: :predicate, index: pred_index, extractor: :scalar }]
            else
              nil # inline literal — not cacheable
            end
          when Arel::Nodes::Between
            and_node = pred.right
            return nil unless and_node.is_a?(Arel::Nodes::And)
            return nil unless bindable_value?(and_node.left) && bindable_value?(and_node.right)
            [
              { source: :predicate, index: pred_index, extractor: :between_left },
              { source: :predicate, index: pred_index, extractor: :between_right }
            ]
          when Arel::Nodes::HomogeneousIn
            [{ source: :predicate, index: pred_index, extractor: :array }]
          when Arel::Nodes::Grouping
            predicate_bind_entries(pred.expr, pred_index)
          else
            nil # uncacheable
          end
        end

      # Collector that collapses add_binds (HomogeneousIn) into a single
      # ArraySubstitute placeholder instead of N individual Substitutes.
      class ShapeAwareCollector < StatementCache::PartialQueryCollector # :nodoc:
        def add_binds(binds, proc_for_binds = nil, &)
          @binds << (proc_for_binds ? binds.map(&proc_for_binds) : binds)
          @parts << StatementCache::ArraySubstitute.new
          self
        end
      end
    end
  end
end
