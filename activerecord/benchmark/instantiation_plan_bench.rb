#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark: Phase 3 — Instantiation Plan Performance
#
# Measures the instantiation cost gap between select_all (SQL only) and
# full AR object instantiation (find_by_sql / where.to_a).
# Tests with a wide model (40+ attributes) to simulate production patterns.

require "bundler/setup"
require "active_record"

ITERATIONS = 5_000
ROWS = 50

ActiveRecord::Base.establish_connection(
  adapter:  "trilogy",
  host:     "127.0.0.1",
  port:     3307,
  username: "root",
  password: "arson",
  database: "arson_bench"
)

ActiveRecord::Schema.define do
  suppress_messages do
    create_table :wide_posts, force: true do |t|
      t.string   :title,       null: false
      t.text     :body
      t.text     :excerpt
      t.integer  :author_id,   null: false
      t.string   :status,      null: false, default: "draft"
      t.integer  :views,       default: 0
      t.integer  :likes,       default: 0
      t.integer  :shares,      default: 0
      t.integer  :comments_count, default: 0
      t.string   :slug
      t.string   :permalink
      t.string   :category
      t.string   :subcategory
      t.string   :locale,      default: "en"
      t.string   :format,      default: "markdown"
      t.string   :visibility,  default: "public"
      t.string   :source
      t.string   :editor_version
      t.string   :content_hash
      t.boolean  :featured,    default: false
      t.boolean  :pinned,      default: false
      t.boolean  :archived,    default: false
      t.boolean  :locked,      default: false
      t.boolean  :allow_comments, default: true
      t.boolean  :show_author,    default: true
      t.float    :reading_time
      t.float    :quality_score
      t.decimal  :revenue,     precision: 10, scale: 2
      t.datetime :published_at
      t.datetime :scheduled_at
      t.datetime :expires_at
      t.datetime :last_edited_at
      t.datetime :featured_at
      t.datetime :indexed_at
      t.date     :publish_date
      t.json     :metadata
      t.json     :settings
      t.string   :meta_title
      t.string   :meta_description
      t.string   :og_image_url
      t.timestamps
    end
    add_index :wide_posts, :author_id
    add_index :wide_posts, :status
  end
end

class WidePost < ActiveRecord::Base
  self.table_name = "wide_posts"
end

# Seed data
WidePost.transaction do
  ROWS.times do |i|
    WidePost.create!(
      title: "Post #{i}", body: "Body content #{i} " * 20, excerpt: "Excerpt #{i}",
      author_id: (i % 50) + 1, status: %w[draft published archived][i % 3],
      views: rand(10000), likes: rand(500), shares: rand(100), comments_count: rand(50),
      slug: "post-#{i}", permalink: "/posts/post-#{i}", category: "tech",
      subcategory: "ruby", locale: "en", format: "markdown", visibility: "public",
      source: "web", editor_version: "2.1", content_hash: SecureRandom.hex(16),
      featured: i % 10 == 0, pinned: i % 20 == 0, archived: false, locked: false,
      allow_comments: true, show_author: true, reading_time: rand(1.0..15.0).round(1),
      quality_score: rand(0.0..1.0).round(3), revenue: rand(0.0..100.0).round(2),
      published_at: rand(365).days.ago, scheduled_at: nil, expires_at: nil,
      last_edited_at: rand(30).days.ago, featured_at: i % 10 == 0 ? rand(30).days.ago : nil,
      indexed_at: 1.hour.ago, publish_date: Date.today - rand(365),
      metadata: { tags: ["ruby", "rails"], version: i }, settings: { theme: "dark" },
      meta_title: "Meta #{i}", meta_description: "Description #{i}",
      og_image_url: "https://example.com/img/#{i}.jpg"
    )
  end
end

conn = WidePost.lease_connection
cache_active = WidePost.query_shape_cache_max_size > 0 && !conn.prepared_statements

puts "=" * 72
puts "PHASE 3: INSTANTIATION PLAN — CPU BENCHMARK"
puts "=" * 72
puts "Branch:              #{`git rev-parse --abbrev-ref HEAD`.strip}"
puts "Commit:              #{`git rev-parse --short HEAD`.strip}"
puts "Cache active:        #{cache_active}"
puts "Model columns:       #{WidePost.column_names.size}"
puts "Rows per query:      #{ROWS}"
puts "Iterations:          #{ITERATIONS}"
puts "=" * 72

ActiveRecord::Base.lease_connection.disable_query_cache!

def cpu_time
  Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
end

def measure(name, iterations: ITERATIONS)
  # Warmup
  5.times { yield }
  GC.start
  GC.compact

  t0_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  t0_cpu = cpu_time
  iterations.times { yield }
  elapsed_cpu = cpu_time - t0_cpu
  elapsed_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0_wall

  wall_us = (elapsed_wall / iterations * 1_000_000).round(1)
  cpu_us = (elapsed_cpu / iterations * 1_000_000).round(1)

  printf "%-35s %10.1fµs wall  %10.1fµs cpu\n", name, wall_us, cpu_us
  cpu_us
end

puts
puts "%-35s %10s        %10s" % ["Benchmark", "Wall/query", "CPU/query"]
puts "-" * 72

# 1. Raw SQL via select_all (baseline — no instantiation)
select_all_cpu = measure("select_all (SQL only)") do
  WidePost.lease_connection.select_all("SELECT * FROM wide_posts WHERE author_id = #{rand(50) + 1}")
end

# 2. Full instantiation via where.to_a (with cache + plan)
full_cpu = measure("where.to_a (cached + plan)") do
  WidePost.where(author_id: rand(50) + 1).to_a
end

# 3. Disable cache and measure uncached where.to_a (full Arel + normal instantiation)
original_max = WidePost.query_shape_cache_max_size
WidePost.query_shape_cache_max_size = 0
WidePost.initialize_find_by_cache

uncached_cpu = measure("where.to_a (no cache)") do
  WidePost.where(author_id: rand(50) + 1).to_a
end

WidePost.query_shape_cache_max_size = original_max
WidePost.initialize_find_by_cache

# 4. Isolated instantiation comparison
result = conn.select_all("SELECT * FROM wide_posts LIMIT 50")
normal_inst_cpu = measure("_load_from_sql (isolated)") do
  WidePost._load_from_sql(result)
end

plan = ActiveRecord::Relation::CachedInstantiationPlan.new(WidePost, result.column_types)
plan_inst_cpu = measure("plan.instantiate (isolated)") do
  plan.instantiate_records(result)
end

puts "-" * 72

puts
puts "ANALYSIS:"
puts "  End-to-end savings (cache+plan vs no cache): #{((1.0 - full_cpu.to_f / uncached_cpu) * 100).round(1)}%"
puts "  Instantiation savings (plan vs normal):       #{((1.0 - plan_inst_cpu.to_f / normal_inst_cpu) * 100).round(1)}%"
puts "  Instantiation gap cached:   #{(full_cpu - select_all_cpu).round(1)}µs"
puts "  Instantiation gap uncached: #{(uncached_cpu - select_all_cpu).round(1)}µs"
puts
puts "METRIC instantiation_savings_pct=#{((1.0 - plan_inst_cpu.to_f / normal_inst_cpu) * 100).round(1)}"
puts "METRIC e2e_savings_pct=#{((1.0 - full_cpu.to_f / uncached_cpu) * 100).round(1)}"
puts
puts "Done."
