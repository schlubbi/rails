# frozen_string_literal: true

require "bundler/setup"
require "active_record"
require "minitest/autorun"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  suppress_messages do
    create_table(:posts) do |t|
      t.string   :title
      t.text     :body
      t.integer  :author_id
      t.string   :status, default: "draft"
      t.boolean  :published, default: false
      t.datetime :published_at
      t.timestamps
    end
    create_table(:comments) do |t|
      t.integer :post_id
      t.text    :body
      t.timestamps
    end
    create_table(:vehicles) do |t|
      t.string  :type
      t.string  :name
      t.integer :wheels
      t.timestamps
    end
  end
end

class Post < ActiveRecord::Base
  has_many :comments

  fast_query :published_recent, ->(limit:) {
    where(status: "published", published: true).order(published_at: :desc).limit(limit)
  }

  fast_query :by_author, ->(author_id:) {
    where(author_id: author_id)
  }

  fast_query :by_status, ->(status:) {
    where(status: status).order(:id)
  }

  fast_query :find_fast, ->(id:) {
    where(id: id).limit(1)
  }

  fast_query :by_author_and_status, ->(author_id:, status:) {
    where(author_id: author_id, status: status).order(:id)
  }

  fast_query :all_published, ->() {
    where(published: true).order(:id)
  }
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class Vehicle < ActiveRecord::Base
  fast_query :by_wheels, ->(wheels:) {
    where(wheels: wheels).order(:id)
  }
end
class Car < Vehicle; end
class Truck < Vehicle; end

class FastQueryTest < Minitest::Test
  def setup
    Post.delete_all
    Comment.delete_all
    Vehicle.delete_all

    t = Time.utc(2026, 6, 17, 12, 0, 0)
    5.times do |i|
      p = Post.create!(
        title: "Post #{i}", body: "Body #{i}", author_id: i % 3,
        status: i < 3 ? "published" : "draft", published: i < 3,
        published_at: i < 3 ? t - (i * 3600) : nil,
        created_at: t, updated_at: t
      )
      Comment.create!(post_id: p.id, body: "Comment #{i}", created_at: t, updated_at: t) if i < 2
    end

    Car.create!(name: "Tesla", wheels: 4, created_at: t, updated_at: t)
    Truck.create!(name: "Ford", wheels: 6, created_at: t, updated_at: t)
    Car.create!(name: "BMW", wheels: 4, created_at: t, updated_at: t)
  end

  # --- Basic functionality ---

  def test_returns_correct_results
    posts = Post.published_recent(limit: 2)
    assert_equal 2, posts.size
    assert_equal "Post 0", posts.first.title
  end

  def test_returns_model_instances
    posts = Post.published_recent(limit: 1)
    assert_kind_of Post, posts.first
  end

  def test_returns_readonly_instances
    posts = Post.published_recent(limit: 1)
    assert posts.first.readonly?
  end

  def test_returns_frozen_array
    posts = Post.published_recent(limit: 1)
    assert posts.frozen?
  end

  def test_attribute_types_are_correct
    post = Post.find_fast(id: Post.first.id).first
    assert_kind_of Integer, post.author_id
    assert_kind_of String, post.title
    assert_includes [TrueClass, FalseClass], post.published.class
    assert_kind_of Time, post.created_at
  end

  # --- Different bind types ---

  def test_integer_bind
    posts = Post.by_author(author_id: 0)
    assert_equal 2, posts.size
    posts.each { |p| assert_equal 0, p.author_id }
  end

  def test_string_bind
    posts = Post.by_status(status: "draft")
    assert_equal 2, posts.size
    posts.each { |p| assert_equal "draft", p.status }
  end

  def test_multiple_binds
    posts = Post.by_author_and_status(author_id: 0, status: "published")
    assert_equal 1, posts.size
    assert_equal 0, posts.first.author_id
    assert_equal "published", posts.first.status
  end

  # --- No binds ---

  def test_no_bind_parameters
    posts = Post.all_published
    assert_equal 3, posts.size
    posts.each { |p| assert p.published }
  end

  # --- Empty results ---

  def test_empty_result
    posts = Post.by_author(author_id: 99999)
    assert_equal [], posts
    assert posts.frozen?
  end

  # --- Cache hits with different values ---

  def test_different_values_return_different_results
    posts_a0 = Post.by_author(author_id: 0)
    posts_a1 = Post.by_author(author_id: 1)
    assert_equal 2, posts_a0.size
    assert_equal 2, posts_a1.size
    refute_equal posts_a0.map(&:id), posts_a1.map(&:id)
  end

  def test_limit_changes_result_count
    posts2 = Post.published_recent(limit: 2)
    posts1 = Post.published_recent(limit: 1)
    assert_equal 2, posts2.size
    assert_equal 1, posts1.size
  end

  # --- Associations ---

  def test_association_loading_works
    post = Post.find_fast(id: Post.first.id).first
    assert_equal 1, post.comments.size
    assert_equal "Comment 0", post.comments.first.body
  end

  # --- STI ---

  def test_sti_discrimination
    vehicles = Vehicle.by_wheels(wheels: 4)
    assert_equal 2, vehicles.size
    vehicles.each { |v| assert_kind_of Car, v }
  end

  def test_sti_different_subclasses
    # Get all vehicles by using a query that returns mixed types
    cars = Vehicle.by_wheels(wheels: 4)
    trucks = Vehicle.by_wheels(wheels: 6)
    assert cars.all? { |v| v.is_a?(Car) }
    assert trucks.all? { |v| v.is_a?(Truck) }
  end

  # --- Readonly enforcement ---

  def test_cannot_save_readonly_instance
    post = Post.find_fast(id: Post.first.id).first
    assert_raises(ActiveRecord::ReadOnlyRecord) { post.save! }
  end

  def test_cannot_destroy_readonly_instance
    post = Post.find_fast(id: Post.first.id).first
    assert_raises(ActiveRecord::ReadOnlyRecord) { post.destroy! }
  end

  # --- Results match normal AR ---

  def test_results_match_normal_query
    fast = Post.published_recent(limit: 3).map { |p| [p.id, p.title, p.status, p.published] }
    normal = Post.where(status: "published", published: true).order(published_at: :desc).limit(3).map { |p| [p.id, p.title, p.status, p.published] }
    assert_equal normal, fast
  end

  def test_string_bind_results_match
    fast = Post.by_status(status: "published").map(&:id).sort
    normal = Post.where(status: "published").order(:id).map(&:id)
    assert_equal normal, fast
  end
end
