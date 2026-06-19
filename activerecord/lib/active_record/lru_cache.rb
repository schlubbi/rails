# frozen_string_literal: true

require "concurrent/map"

module ActiveRecord
  # A thread-safe LRU cache backed by a Concurrent::Map for lock-free reads
  # and a Mutex for eviction on writes. Used by the query shape cache.
  #
  # Read path: lock-free via Concurrent::Map
  # Write path: Mutex-protected to maintain LRU eviction order
  class LruCache # :nodoc:
    attr_reader :max_size

    def initialize(max_size)
      raise ArgumentError, "max_size must be non-negative" unless max_size >= 0
      @max_size = max_size
      @map = Concurrent::Map.new
      @order = []  # LRU order: most recently used at the end
      @mutex = Mutex.new
    end

    def get(key)
      return nil if @max_size == 0
      value = @map[key]
      if value
        # Move to end (most recently used) — best-effort, no lock needed for correctness
        @mutex.synchronize do
          @order.delete(key)
          @order.push(key)
        end
      end
      value
    end

    def set(key, value)
      return value if @max_size == 0
      @mutex.synchronize do
        unless @map.key?(key)
          # Evict least recently used if at capacity
          while @order.size >= @max_size
            evict_key = @order.shift
            @map.delete(evict_key) if evict_key
          end
        else
          @order.delete(key)
        end

        @map[key] = value
        @order.push(key)
      end
      value
    end

    def size
      @map.size
    end

    def clear
      @mutex.synchronize do
        @map.clear
        @order.clear
      end
    end
  end
end
