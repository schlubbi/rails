# frozen_string_literal: true

require "active_record/relation/cached_instantiation_plan"

module ActiveRecord
  class Relation
    # Cached representation of a compiled query shape. Stored in the model's
    # query_shape_cache, keyed by a shape fingerprint that excludes bind values.
    #
    # On cache hit, the PartialQuery template is reused with new bind values
    # substituted in, skipping the entire Arel AST construction and visitor
    # traversal.
    class CachedQueryShape # :nodoc:
      attr_reader :query_builder, :bind_map, :instantiation_plan

      # query_builder - A StatementCache::PartialQuery (or Query) that holds
      #   SQL fragments with Substitute/ArraySubstitute placeholders
      # bind_map - An array of bind source descriptors, each a Hash:
      #   { source: :predicate, index: N, array: false }
      #   { source: :predicate, index: N, array: true }
      #   { source: :limit }
      #   { source: :offset }
      # instantiation_plan - A CachedInstantiationPlan (or nil if not yet populated)
      def initialize(query_builder, bind_map, instantiation_plan = nil)
        @query_builder = query_builder
        @bind_map = bind_map.freeze
        @instantiation_plan = instantiation_plan
        freeze
      end

      # Return a new CachedQueryShape with the instantiation plan attached.
      def with_instantiation_plan(plan)
        CachedQueryShape.new(@query_builder, @bind_map, plan)
      end
    end
  end
end
