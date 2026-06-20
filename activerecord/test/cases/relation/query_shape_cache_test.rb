# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"
require "models/author"
require "models/topic"
require "models/reply"

module ActiveRecord
  class QueryShapeCacheTest < ActiveRecord::TestCase
    fixtures :posts, :comments, :authors, :topics, :customers

    setup do
      @original_max_size = ActiveRecord::Base.query_shape_cache_max_size
      # Only runs when prepared_statements is false (like Trilogy)
      # Force it for testing by using a connection without prepared statements
    end

    teardown do
      ActiveRecord::Base.query_shape_cache_max_size = @original_max_size
      # Restore prepared_statements if we changed it
      if defined?(@original_prepared)
        Post.lease_connection.instance_variable_set(:@prepared_statements, @original_prepared)
      end
      Post.query_shape_cache.clear
      Comment.query_shape_cache.clear
    end

    # --- Cache population and hit ---

    test "caches query shape on first execution and reuses on second" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: 1).order(:id).limit(10).to_a
      assert_equal 1, Post.query_shape_cache.size

      # Same shape, different values — should hit cache
      Post.where(id: 2).order(:id).limit(5).to_a
      assert_equal 1, Post.query_shape_cache.size, "Same shape should not create a new cache entry"
    end

    test "different shapes produce different cache entries" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: 1).to_a
      Post.where(title: "hello").to_a

      assert_equal 2, Post.query_shape_cache.size
    end

    test "cached query returns correct results" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      result1 = Post.where(id: posts(:welcome).id).to_a
      result2 = Post.where(id: posts(:thinking).id).to_a

      assert_equal [posts(:welcome)], result1
      assert_equal [posts(:thinking)], result2
    end

    # --- IN clause with varying lengths ---

    test "IN clause with different array lengths shares cache entry" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: [1, 2]).to_a
      Post.where(id: [1, 2, 3, 4, 5]).to_a

      assert_equal 1, Post.query_shape_cache.size,
        "IN clause with different array lengths should share a single cache entry"
    end

    test "IN clause returns correct results regardless of array length" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      result1 = Post.where(id: [posts(:welcome).id]).to_a
      result2 = Post.where(id: [posts(:welcome).id, posts(:thinking).id]).to_a

      assert_equal [posts(:welcome)], result1
      assert_includes result2, posts(:welcome)
      assert_includes result2, posts(:thinking)
      assert_equal 2, result2.size
    end

    # --- Null handling ---

    test "null equality and non-null equality are different shapes" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(author_id: nil).to_a
      Post.where(author_id: 1).to_a

      assert_equal 2, Post.query_shape_cache.size,
        "NULL and non-NULL should be different cache keys"
    end

    # --- Unsupported cases fall through ---

    test "queries with joins are not cached" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.joins(:comments).where(id: 1).to_a

      assert_equal 0, Post.query_shape_cache.size
    end

    test "queries with includes are not cached" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.includes(:comments).where(id: 1).to_a

      assert_equal 0, Post.query_shape_cache.size
    end

    test "queries with from clause are not cached" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.from("posts").where(id: 1).to_a

      assert_equal 0, Post.query_shape_cache.size
    end

    test "queries with or are not cached" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: 1).or(Post.where(id: 2)).to_a

      assert_equal 0, Post.query_shape_cache.size
    end

    test "queries with raw SQL where clause are not cached" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where("id = ?", 1).to_a

      assert_equal 0, Post.query_shape_cache.size
    end

    # --- Range queries (Between) ---

    test "range queries are cached and return correct results" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      result1 = Post.where(id: 1..3).to_a
      assert_equal 1, Post.query_shape_cache.size

      result2 = Post.where(id: 5..10).to_a
      assert_equal 1, Post.query_shape_cache.size, "Same range shape should reuse cache"
    end

    # --- Order, limit, offset ---

    test "different order directions are different shapes" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.order(:id).to_a
      Post.order(id: :desc).to_a

      assert_equal 2, Post.query_shape_cache.size
    end

    test "with and without limit are different shapes" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: 1).to_a
      Post.where(id: 1).limit(5).to_a

      assert_equal 2, Post.query_shape_cache.size
    end

    # --- Cache invalidation ---

    test "reset_column_information clears the query shape cache" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(id: 1).to_a
      assert_equal 1, Post.query_shape_cache.size

      Post.reset_column_information
      assert_equal 0, Post.query_shape_cache.size
    end

    # --- Configuration ---

    test "disabling query shape cache with max_size 0" do
      skip_if_prepared_statements!

      Post.query_shape_cache_max_size = 0
      Post.initialize_find_by_cache
      Post.where(id: 1).to_a

      assert_equal 0, Post.query_shape_cache.size
    ensure
      Post.query_shape_cache_max_size = @original_max_size
      Post.initialize_find_by_cache
    end

    # --- LRU eviction ---

    test "LRU cache evicts oldest entries when full" do
      cache = ActiveRecord::LruCache.new(3)
      cache.set(:a, 1)
      cache.set(:b, 2)
      cache.set(:c, 3)
      assert_equal 3, cache.size

      cache.set(:d, 4)
      assert_equal 3, cache.size
      assert_nil cache.get(:a), "Oldest entry should be evicted"
      assert_equal 4, cache.get(:d)
    end

    test "LRU cache promotes accessed entries" do
      cache = ActiveRecord::LruCache.new(3)
      cache.set(:a, 1)
      cache.set(:b, 2)
      cache.set(:c, 3)

      # Access :a to promote it
      cache.get(:a)

      # Insert :d — should evict :b (least recently used), not :a
      cache.set(:d, 4)
      assert_equal 1, cache.get(:a), ":a should still exist after promotion"
      assert_nil cache.get(:b), ":b should be evicted"
    end

    # --- Multiple where clauses chained ---

    test "chained where clauses produce correct cached SQL" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      result1 = Post.where(author_id: authors(:david).id).where(type: "Post").to_a
      assert_equal 1, Post.query_shape_cache.size

      result2 = Post.where(author_id: authors(:mary).id).where(type: "Post").to_a
      assert_equal 1, Post.query_shape_cache.size, "Chained where with same structure should share cache"
    end

    # --- Distinct, group ---

    test "distinct queries are cached separately" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      Post.where(author_id: 1).to_a
      Post.where(author_id: 1).distinct.to_a

      assert_equal 2, Post.query_shape_cache.size
    end

    private
      def skip_if_prepared_statements!
        if current_adapter_uses_prepared_statements?
          # Temporarily disable prepared statements for this test
          connection = Post.lease_connection
          @original_prepared = connection.instance_variable_get(:@prepared_statements)
          connection.instance_variable_set(:@prepared_statements, false)
        end
      end

      def current_adapter_uses_prepared_statements?
        Post.lease_connection.prepared_statements
      end
  end

  class QueryShapeCacheInstantiationPlanTest < ActiveRecord::TestCase
    fixtures :posts, :comments, :authors, :topics

    setup do
      @original_max_size = ActiveRecord::Base.query_shape_cache_max_size
      Post.query_shape_cache.clear
      Topic.query_shape_cache.clear
    end

    teardown do
      ActiveRecord::Base.query_shape_cache_max_size = @original_max_size
      if defined?(@original_prepared)
        Post.lease_connection.instance_variable_set(:@prepared_statements, @original_prepared)
      end
      Post.query_shape_cache.clear
      Topic.query_shape_cache.clear
    end

    # --- Instantiation plan caching ---

    test "instantiation plan is cached on second cache hit" do
      skip_if_prepared_statements!

      # First query: cache miss (builds SQL cache entry)
      Post.where(author_id: authors(:david).id).to_a

      # Second query: cache hit (builds + stores instantiation plan)
      Post.where(author_id: authors(:mary).id).to_a

      # Verify plan is cached
      cached = get_first_cached_shape(Post)
      assert_not_nil cached.instantiation_plan
      assert_equal Post, cached.instantiation_plan.model_class
    end

    test "instantiation plan produces correct records" do
      skip_if_prepared_statements!

      # Warm the cache
      Post.where(author_id: authors(:david).id).to_a

      # This hit uses the plan
      result = Post.where(author_id: authors(:mary).id).to_a

      assert result.all? { |r| r.is_a?(Post) }
      assert result.all? { |r| r.author_id == authors(:mary).id }
      assert result.none?(&:new_record?)
    end

    test "instantiation plan returns correct attribute values" do
      skip_if_prepared_statements!

      post = posts(:welcome)

      # Warm
      Post.where(id: post.id + 1000).to_a

      # Hit with plan
      result = Post.where(id: post.id).to_a
      assert_equal 1, result.size
      assert_equal post.id, result.first.id
      assert_equal post.title, result.first.title
      assert_equal post.author_id, result.first.author_id
    end

    # --- STI with instantiation plan ---

    test "instantiation plan handles STI correctly" do
      skip_if_prepared_statements!

      Topic.query_shape_cache.clear

      # Create topics with different types
      topic = Topic.create!(title: "Plain Topic")
      reply = Reply.create!(title: "A Reply", parent_id: topic.id, content: "reply content")

      # Warm cache
      Topic.where(title: "Plain Topic").to_a

      # Hit with STI — should instantiate correct subclass
      result = Topic.where(title: "A Reply").to_a
      assert_equal 1, result.size
      assert_equal Reply, result.first.class
      assert_equal "A Reply", result.first.title
    ensure
      reply&.destroy
      topic&.destroy
    end

    # --- Callbacks with instantiation plan ---

    test "after_find and after_initialize callbacks still fire with plan" do
      skip_if_prepared_statements!

      Topic.query_shape_cache.clear

      # Topic has after_initialize callbacks
      Topic.where(id: topics(:first).id + 10000).to_a # Warm with no results won't cache plan

      # Actually warm properly
      Topic.where(id: topics(:first).id).to_a

      # Second hit uses plan — callbacks must still fire
      Topic.after_initialize_called = false
      result = Topic.where(id: topics(:first).id).to_a
      assert_equal true, Topic.after_initialize_called,
        "after_initialize should still be called when using instantiation plan"
    end

    test "skip_callbacks is true for models without after_find/after_initialize" do
      skip_if_prepared_statements!

      # Post has no after_find/after_initialize by default
      Post.where(id: 1).to_a
      Post.where(id: 2).to_a

      cached = get_first_cached_shape(Post)
      assert cached.instantiation_plan.skip_callbacks,
        "Plan should mark callbacks as skippable for Post"
    end

    test "skip_callbacks is false for models with after_find/after_initialize" do
      skip_if_prepared_statements!

      Topic.query_shape_cache.clear
      Topic.where(id: topics(:first).id).to_a
      Topic.where(id: topics(:second).id).to_a

      cached = get_first_cached_shape(Topic)
      assert_not cached.instantiation_plan.skip_callbacks,
        "Plan should NOT mark callbacks as skippable for Topic"
    end

    # --- readonly / strict_loading still applied ---

    test "readonly is applied to records from instantiation plan" do
      skip_if_prepared_statements!

      Post.where(id: 1).to_a # warm
      result = Post.readonly.where(id: posts(:welcome).id).to_a

      assert result.first.readonly?
    end

    test "strict_loading is applied to records from instantiation plan" do
      skip_if_prepared_statements!

      Post.where(id: 1).to_a # warm
      result = Post.strict_loading.where(id: posts(:welcome).id).to_a

      assert result.first.strict_loading?
    end

    # --- select() with instantiation plan ---

    test "select with subset of columns works with plan" do
      skip_if_prepared_statements!

      Post.select(:id, :title).where(author_id: 1).to_a # warm
      result = Post.select(:id, :title).where(author_id: authors(:david).id).to_a

      assert result.first.has_attribute?(:id)
      assert result.first.has_attribute?(:title)
      assert_equal posts(:welcome).title, result.first.title if result.any?
    end

    # --- Thread safety ---

    test "instantiation plan is frozen and thread-safe" do
      skip_if_prepared_statements!

      Post.where(id: 1).to_a
      Post.where(id: 2).to_a

      cached = get_first_cached_shape(Post)
      plan = cached.instantiation_plan

      assert plan.frozen?
      assert plan.additional_types.frozen?
    end

    # --- Block passed to instantiate ---

    test "block is yielded to each record with plan" do
      skip_if_prepared_statements!

      Post.where(author_id: 1).to_a # warm

      yielded = []
      Post.where(author_id: authors(:david).id).each { |r| yielded << r.id }

      assert yielded.any?
      assert yielded.all? { |id| id.is_a?(Integer) }
    end

    private
      def skip_if_prepared_statements!
        if Post.lease_connection.prepared_statements
          connection = Post.lease_connection
          @original_prepared = connection.instance_variable_get(:@prepared_statements)
          connection.instance_variable_set(:@prepared_statements, false)
        end
      end

      def get_first_cached_shape(klass)
        # Access the internal LRU cache map to find the stored shape
        cache = klass.query_shape_cache
        map = cache.instance_variable_get(:@map)
        _, shape = map.each_pair.first
        shape
      end
  end

  class QueryShapeCacheBugRegressionTest < ActiveRecord::TestCase
    fixtures :posts, :comments, :authors, :topics

    setup do
      @original_max_size = ActiveRecord::Base.query_shape_cache_max_size
      Post.query_shape_cache.clear
      Comment.query_shape_cache.clear
      Topic.query_shape_cache.clear
    end

    teardown do
      ActiveRecord::Base.query_shape_cache_max_size = @original_max_size
      if defined?(@original_prepared)
        Post.lease_connection.instance_variable_set(:@prepared_statements, @original_prepared)
      end
      Post.query_shape_cache.clear
      Comment.query_shape_cache.clear
      Topic.query_shape_cache.clear
    end

    # --- Bug 1: Missing association_cache / aggregation_cache ivars ---

    test "cache-hit records have working association access" do
      skip_if_prepared_statements!

      post = posts(:welcome)
      Post.where(id: post.id).to_a # miss
      result = Post.where(id: post.id).to_a # hit with plan

      # This would blow up with "undefined method for nil" if @association_cache
      # wasn't initialized
      assert_nothing_raised do
        result.first.comments
      end
    end

    test "cache-hit records can be reloaded" do
      skip_if_prepared_statements!

      Post.where(id: posts(:welcome).id).to_a # miss
      result = Post.where(id: posts(:welcome).id).to_a # hit

      assert_nothing_raised do
        result.first.reload
      end
      assert_equal posts(:welcome).title, result.first.title
    end

    # --- Bug 2a: Bind map desync with NULL predicates ---

    test "where with nil and bound values returns correct results on cache hit" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear

      # Create posts: one with nil author, one with author
      p1 = Post.create!(title: "nil author", author_id: 0, body: "first")
      p2 = Post.create!(title: "nil author2", author_id: 0, body: "second")

      # Mix of IS NULL and bound predicate: where(type: nil, body: "first")
      # type IS NULL emits 0 binds; body = ? emits 1 bind.
      result1 = Post.where(type: nil, body: "first").to_a # miss
      assert_includes result1.map(&:id), p1.id

      # Cache hit — the body bind must not desync
      result2 = Post.where(type: nil, body: "second").to_a # hit
      assert_includes result2.map(&:id), p2.id
      assert_not_includes result2.map(&:id), p1.id,
        "Cache hit with NULL predicate should not confuse bind positions"
    ensure
      p1&.destroy
      p2&.destroy
    end

    # --- Bug 2b: Single-element array collapse ---

    test "where with single-element array returns correct result on cache hit" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear

      # where(id: [X]) — Rails collapses to scalar =, but raw value is [X]
      result1 = Post.where(id: [posts(:welcome).id]).to_a # miss
      assert_equal [posts(:welcome).id], result1.map(&:id)

      # Cache hit — must unwrap the single-element array correctly
      result2 = Post.where(id: [posts(:thinking).id]).to_a # hit
      assert_equal [posts(:thinking).id], result2.map(&:id),
        "Single-element array should be unwrapped on cache hit"
    end

    test "where with Set returns correct result on cache hit" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear

      result1 = Post.where(id: Set[posts(:welcome).id]).to_a # miss
      assert_equal [posts(:welcome).id], result1.map(&:id)

      result2 = Post.where(id: Set[posts(:thinking).id]).to_a # hit
      assert_equal [posts(:thinking).id], result2.map(&:id),
        "Single-element Set should be unwrapped on cache hit"
    end

    test "where with multi-element array uses IN and returns correct results" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear
      ids1 = [posts(:welcome).id, posts(:thinking).id]
      ids2 = [posts(:welcome).id]

      result1 = Post.where(id: ids1).to_a # miss
      assert_equal ids1.sort, result1.map(&:id).sort

      result2 = Post.where(id: ids2).to_a # hit (different array length)
      assert_equal ids2, result2.map(&:id)
    end

    # --- STI subclass direct query (implicit type predicate) ---

    test "STI subclass direct query returns correct results on cache hit" do
      skip_if_prepared_statements!

      # StiPost < Post adds an implicit where(type: 'StiPost')
      StiPost.query_shape_cache.clear

      sp1 = StiPost.create!(title: "STI One", author_id: 1, body: "a")
      sp2 = StiPost.create!(title: "STI Two", author_id: 2, body: "b")

      result1 = StiPost.where(author_id: 1).to_a # miss
      assert result1.all? { |r| r.is_a?(StiPost) }
      assert_includes result1.map(&:id), sp1.id

      result2 = StiPost.where(author_id: 2).to_a # hit
      assert result2.all? { |r| r.is_a?(StiPost) }
      assert_includes result2.map(&:id), sp2.id
      assert_not_includes result2.map(&:id), sp1.id
    ensure
      sp1&.destroy
      sp2&.destroy
    end

    # --- Cache-hit SQL matches uncached SQL ---

    test "cache-hit SQL is identical to uncached SQL" do
      skip_if_prepared_statements!

      Post.query_shape_cache.clear

      # Miss — capture the SQL
      uncached_sql = nil
      callback = ->(_name, _start, _finish, _id, payload) {
        uncached_sql = payload[:sql] if payload[:sql]&.include?("posts")
      }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Post.where(author_id: 1).to_a
      end

      # Hit — capture the SQL
      cached_sql = nil
      callback2 = ->(_name, _start, _finish, _id, payload) {
        cached_sql = payload[:sql] if payload[:sql]&.include?("posts")
      }
      ActiveSupport::Notifications.subscribed(callback2, "sql.active_record") do
        Post.where(author_id: 2).to_a
      end

      # SQL should differ only in the bind value
      assert uncached_sql.present?
      assert cached_sql.present?
      # Normalize bind values for comparison
      normalized_uncached = uncached_sql.gsub(/= \d+/, "= ?")
      normalized_cached = cached_sql.gsub(/= \d+/, "= ?")
      assert_equal normalized_uncached, normalized_cached,
        "Cached SQL shape should match uncached SQL shape"
    end

    private
      def skip_if_prepared_statements!
        if Post.lease_connection.prepared_statements
          connection = Post.lease_connection
          @original_prepared = connection.instance_variable_get(:@prepared_statements)
          connection.instance_variable_set(:@prepared_statements, false)
        end
      end
  end
end
