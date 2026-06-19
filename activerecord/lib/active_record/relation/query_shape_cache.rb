# frozen_string_literal: true

module ActiveRecord
  class Relation
    module QueryShapeCache # :nodoc:
      private

        # Check cache and return [sql, retryable] or nil.
        def find_cached_query_shape(connection)
          return unless cacheable_query_shape?

          key = query_shape_key
          return unless key

          cached = model.query_shape_cache.get(key)
          return unless cached

          binds = extract_shape_binds(cached.bind_map)
          sql = cached.query_builder.sql_for(binds, connection)
          [sql, cached.query_builder.retryable]
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

          # Model identity
          parts << model.object_id

          # Where clause shape
          where_clause.predicates.each do |pred|
            shape = predicate_shape(pred)
            return nil unless shape
            parts << shape
          end

          # Order shape
          if order_values.any?
            order_values.each do |o|
              shape = order_shape(o)
              return nil unless shape
              parts << shape
            end
          end

          # Limit/offset presence
          parts << :limit if limit_value
          parts << :offset if offset_value

          # Distinct
          parts << :distinct if distinct_value

          # Lock
          parts << [:lock, lock_value] if lock_value

          # Select columns
          if select_values.any?
            select_shapes = select_values.map { |s| select_shape(s) }
            return nil if select_shapes.any?(&:nil?)
            parts << [:select, select_shapes]
          end

          # Group by
          if group_values.any?
            group_shapes = group_values.map { |g| group_shape(g) }
            return nil if group_shapes.any?(&:nil?)
            parts << [:group, group_shapes]
          end

          parts.hash
        end

        def predicate_shape(pred)
          case pred
          when Arel::Nodes::Equality
            if pred.left.respond_to?(:name)
              if pred.right.nil?
                [:eq_null, pred.left.name]
              elsif unboundable_value?(pred.right)
                [:eq_unbound, pred.left.name]
              else
                [:eq, pred.left.name]
              end
            end
          when Arel::Nodes::NotEqual
            if pred.left.respond_to?(:name)
              if pred.right.nil?
                [:neq_null, pred.left.name]
              else
                [:neq, pred.left.name]
              end
            end
          when Arel::Nodes::HomogeneousIn
            [:in, pred.attribute.name, pred.type]
          when Arel::Nodes::Between
            [:between, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::GreaterThan
            [:gt, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::GreaterThanOrEqual
            [:gteq, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::LessThan
            [:lt, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::LessThanOrEqual
            [:lteq, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::IsNotDistinctFrom
            [:indist, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::IsDistinctFrom
            [:dist, pred.left.name] if pred.left.respond_to?(:name)
          when Arel::Nodes::Grouping
            inner = predicate_shape(pred.expr)
            inner ? [:group, inner] : nil
          else
            nil
          end
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

        # Build a bind_map from the binds collected during compilation.
        # Each entry describes how to extract the bind value on cache hit.
        #
        # The bind_map is an array of descriptors:
        #   { source: :predicate, index: N, extractor: :scalar }
        #   { source: :predicate, index: N, extractor: :array }
        #   { source: :limit }
        #   { source: :offset }
        def build_bind_map_from_binds(binds)
          bind_map = []
          pred_bind_index = 0  # which predicate we're matching
          preds = where_clause.predicates
          pred_remaining_scalars = 0  # for Between (2 scalars from one predicate)

          binds.each do |bind|
            if bind.respond_to?(:name) && bind.name == "LIMIT"
              bind_map << { source: :limit }
              next
            end

            if bind.respond_to?(:name) && bind.name == "OFFSET"
              bind_map << { source: :offset }
              next
            end

            # It's a predicate bind. If it's an Array, it's from HomogeneousIn
            # via ShapeAwareCollector#add_binds which collapses all values into one entry.
            if bind.is_a?(Array)
              bind_map << { source: :predicate, index: pred_bind_index, extractor: :array }
              pred_bind_index += 1
              next
            end

            # Scalar predicate bind
            if pred_remaining_scalars > 0
              # Continuation of a multi-bind predicate (Between)
              pred_remaining_scalars -= 1
              bind_map << { source: :predicate, index: pred_bind_index, extractor: :between_right }
              if pred_remaining_scalars == 0
                pred_bind_index += 1
              end
              next
            end

            pred = preds[pred_bind_index]
            return nil unless pred  # more binds than predicates — uncacheable

            case pred
            when Arel::Nodes::Between
              # Between emits 2 scalar binds — mark first as :between_left, second as :between_right
              bind_map << { source: :predicate, index: pred_bind_index, extractor: :between_left }
              pred_remaining_scalars = 1  # one more to come
            else
              bind_map << { source: :predicate, index: pred_bind_index, extractor: :scalar }
              pred_bind_index += 1
            end
          end

          bind_map
        end

        # Extract bind values from the current relation's state,
        # in the order the cached SQL template expects.
        def extract_shape_binds(bind_map)
          binds = []
          preds = where_clause.predicates

          bind_map.each do |desc|
            case desc[:source]
            when :predicate
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

        # Extract a single scalar bind value from a predicate node.
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
