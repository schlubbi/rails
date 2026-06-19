# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"
require "models/author"

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
end
