# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/author"
require "models/comment"

class QueryShapeCacheTest < ActiveRecord::TestCase
  fixtures :posts, :authors, :comments

  def setup
    @cache = ActiveRecord::QueryShapeCache.new
  end

  # --- Shape Key Tests ---

  def test_same_shape_different_values_produce_same_key
    r1 = Post.where(title: "foo")
    r2 = Post.where(title: "bar")
    assert_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_same_shape_different_limit_values_produce_same_key
    r1 = Post.where(title: "foo").limit(5)
    r2 = Post.where(title: "bar").limit(10)
    assert_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_different_columns_produce_different_keys
    r1 = Post.where(title: "foo")
    r2 = Post.where(author_id: 1)
    assert_not_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_different_order_produces_different_key
    r1 = Post.where(title: "foo").order(:created_at)
    r2 = Post.where(title: "foo").order(created_at: :desc)
    k1 = @cache.shape_key(r1)
    k2 = @cache.shape_key(r2)
    assert_not_nil k1, "order(:created_at) should be cacheable"
    assert_not_nil k2, "order(created_at: :desc) should be cacheable"
    assert_not_equal k1, k2
  end

  def test_with_limit_vs_without_produces_different_key
    r1 = Post.where(title: "foo")
    r2 = Post.where(title: "foo").limit(5)
    assert_not_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_with_select_vs_star_produces_different_key
    r1 = Post.where(title: "foo")
    r2 = Post.select(:id, :title).where(title: "foo")
    assert_not_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_in_list_with_different_sizes_produce_different_keys
    r1 = Post.where(id: [1, 2, 3])
    r2 = Post.where(id: [1, 2])
    assert_not_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_distinct_vs_not_produces_different_key
    r1 = Post.where(title: "foo")
    r2 = Post.where(title: "foo").distinct
    assert_not_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  def test_where_column_order_does_not_matter
    r1 = Post.where(title: "foo", author_id: 1)
    r2 = Post.where(author_id: 1, title: "foo")
    assert_equal @cache.shape_key(r1), @cache.shape_key(r2)
  end

  # --- Non-cacheable patterns return nil ---

  def test_string_sql_where_is_not_cacheable
    r = Post.where("title = ?", "foo")
    assert_nil @cache.shape_key(r)
  end

  def test_joins_is_not_cacheable
    r = Post.joins(:comments).where(title: "foo")
    assert_nil @cache.shape_key(r)
  end

  def test_group_is_not_cacheable
    r = Post.where(title: "foo").group(:author_id)
    assert_nil @cache.shape_key(r)
  end

  def test_having_is_not_cacheable
    r = Post.where(title: "foo").having("count(*) > 1")
    assert_nil @cache.shape_key(r)
  end

  def test_lock_is_not_cacheable
    r = Post.where(title: "foo").lock
    assert_nil @cache.shape_key(r)
  end

  def test_raw_sql_order_is_not_cacheable
    r = Post.where(title: "foo").order("title DESC")
    assert_nil @cache.shape_key(r)
  end

  # --- Cache lookup/record ---

  def test_lookup_returns_nil_on_miss
    r = Post.where(title: "foo")
    assert_nil @cache.lookup(r)
  end

  def test_record_and_lookup
    r = Post.where(title: "foo")
    @cache.record(r, "SELECT * FROM posts WHERE title = ?", true, true)

    result = @cache.lookup(r)
    assert_not_nil result
    entry, binds = result
    assert_equal "SELECT * FROM posts WHERE title = ?", entry.sql
    assert_equal true, entry.preparable
    assert_equal true, entry.retryable
  end

  def test_lookup_extracts_correct_binds
    r = Post.where(title: "hello").limit(5)
    @cache.record(r, "SELECT * FROM posts WHERE title = ? LIMIT ?", true, true)

    _entry, binds = @cache.lookup(r)
    bind_values = binds.map { |b| b.respond_to?(:value_for_database) ? b.value_for_database : b }
    assert_equal "hello", bind_values[0]
    assert_equal 5, bind_values[1]
  end

  def test_cache_hit_with_different_values
    r1 = Post.where(title: "hello")
    @cache.record(r1, "SELECT * FROM posts WHERE title = ?", true, true)

    r2 = Post.where(title: "world")
    result = @cache.lookup(r2)
    assert_not_nil result, "Same shape should hit cache"

    _entry, binds = result
    bind_values = binds.map { |b| b.respond_to?(:value_for_database) ? b.value_for_database : b }
    assert_equal "world", bind_values[0]
  end

  def test_clear_empties_cache
    r = Post.where(title: "foo")
    @cache.record(r, "SELECT ...", true, true)
    assert_equal 1, @cache.size

    @cache.clear!
    assert_equal 0, @cache.size
    assert_nil @cache.lookup(r)
  end

  # --- Integration: identical results with and without cache ---

  def test_cached_query_returns_same_results_as_uncached
    Post.query_shape_cache_enabled = false
    expected = Post.where(author_id: 1).order(:created_at).to_a

    Post.query_shape_cache_enabled = true
    Post.clear_query_shape_cache!

    # First call: cache miss
    actual_miss = Post.where(author_id: 1).order(:created_at).to_a
    # Second call: cache hit
    actual_hit = Post.where(author_id: 1).order(:created_at).to_a

    assert_equal expected.map(&:id), actual_miss.map(&:id), "Cache miss should return same results"
    assert_equal expected.map(&:id), actual_hit.map(&:id), "Cache hit should return same results"
  ensure
    Post.query_shape_cache_enabled = false
  end

  def test_cached_query_with_limit_returns_same_results
    Post.query_shape_cache_enabled = false
    expected = Post.where(author_id: 1).limit(2).to_a

    Post.query_shape_cache_enabled = true
    Post.clear_query_shape_cache!

    actual_miss = Post.where(author_id: 1).limit(2).to_a
    actual_hit = Post.where(author_id: 1).limit(2).to_a

    assert_equal expected.map(&:id), actual_miss.map(&:id)
    assert_equal expected.map(&:id), actual_hit.map(&:id)
  ensure
    Post.query_shape_cache_enabled = false
  end

  def test_non_cacheable_query_falls_back_gracefully
    Post.query_shape_cache_enabled = true
    Post.clear_query_shape_cache!

    expected = Post.where("author_id = ?", 1).to_a
    actual = Post.where("author_id = ?", 1).to_a

    assert_equal expected.map(&:id), actual.map(&:id)
    assert_equal 0, Post.query_shape_cache_store.size, "Non-cacheable queries should not populate cache"
  ensure
    Post.query_shape_cache_enabled = false
  end

  def test_cache_invalidated_on_schema_change
    Post.query_shape_cache_enabled = true
    Post.clear_query_shape_cache!
    Post.where(title: "foo").to_a
    assert Post.query_shape_cache_store.size > 0

    Post.reset_column_information
    assert_equal 0, Post.query_shape_cache_store.size
  ensure
    Post.query_shape_cache_enabled = false
  end
end
