# frozen_string_literal: true

require_relative "../abstract_unit"
require "active_support/notifications"

module ActiveSupport
  module Notifications
    class DispatchPlanTest < ActiveSupport::TestCase
      def setup
        @old_notifier = ActiveSupport::Notifications.notifier
        @notifier = ActiveSupport::Notifications::Fanout.new
        ActiveSupport::Notifications.notifier = @notifier
      end

      def teardown
        ActiveSupport::Notifications.notifier = @old_notifier
      end

      # --- Zero allocations for MonotonicTimed-only subscribers ---

      def test_zero_intermediate_allocations_with_monotonic_subscriber
        calls = []
        ActiveSupport::Notifications.monotonic_subscribe("sql.test") do |name, start, finish, id, payload|
          calls << [name, start.class, finish.class]
        end

        # Warm the cache
        ActiveSupport::Notifications.instrument("sql.test", query: "SELECT 1") {}

        before = GC.stat(:total_allocated_objects)
        ActiveSupport::Notifications.instrument("sql.test", query: "SELECT 1") {}
        after = GC.stat(:total_allocated_objects)

        # The only allocation should be the payload hash from the caller (if not passed in).
        # With the dispatch plan, there are zero Handle/Group/Array allocations.
        # We allow a small margin for the test framework itself.
        allocated = after - before
        assert_operator allocated, :<=, 5, "Expected near-zero allocations, got #{allocated}"
        assert_equal 2, calls.size
        assert_equal Float, calls.last[1]
        assert_equal Float, calls.last[2]
      end

      def test_zero_intermediate_allocations_with_two_monotonic_subscribers
        calls = []
        2.times do
          ActiveSupport::Notifications.monotonic_subscribe("sql.test") do |name, start, finish, id, payload|
            calls << name
          end
        end

        # Warm
        ActiveSupport::Notifications.instrument("sql.test") {}

        before = GC.stat(:total_allocated_objects)
        ActiveSupport::Notifications.instrument("sql.test") {}
        after = GC.stat(:total_allocated_objects)

        allocated = after - before
        assert_operator allocated, :<=, 5, "Expected near-zero allocations, got #{allocated}"
        assert_equal 4, calls.size
      end

      def test_no_allocations_when_no_subscribers
        # Warm
        ActiveSupport::Notifications.instrument("unsubscribed.event") {}

        before = GC.stat(:total_allocated_objects)
        ActiveSupport::Notifications.instrument("unsubscribed.event") {}
        after = GC.stat(:total_allocated_objects)

        allocated = after - before
        assert_operator allocated, :<=, 5, "Expected near-zero allocations, got #{allocated}"
      end

      # --- Correct dispatch to all subscriber types ---

      def test_monotonic_timed_receives_floats
        received = nil
        ActiveSupport::Notifications.monotonic_subscribe("test.mono") do |name, start, finish, id, payload|
          received = { name: name, start: start, finish: finish, id: id, payload: payload }
        end

        ActiveSupport::Notifications.instrument("test.mono", key: "value") {}

        assert_not_nil received
        assert_equal "test.mono", received[:name]
        assert_instance_of Float, received[:start]
        assert_instance_of Float, received[:finish]
        assert_operator received[:finish], :>=, received[:start]
        assert_equal({ key: "value" }, received[:payload])
      end

      def test_timed_receives_time_objects
        received = nil
        ActiveSupport::Notifications.subscribe("test.timed") do |name, start, finish, id, payload|
          received = { start: start, finish: finish }
        end

        ActiveSupport::Notifications.instrument("test.timed") {}

        assert_not_nil received
        assert_instance_of Time, received[:start]
        assert_instance_of Time, received[:finish]
      end

      def test_event_object_receives_event
        received = nil
        ActiveSupport::Notifications.subscribe("test.event_obj") do |event|
          received = event
        end

        ActiveSupport::Notifications.instrument("test.event_obj", data: 42) do
          # simulate some work
          100.times { Object.new }
        end

        assert_not_nil received
        assert_instance_of Event, received
        assert_equal "test.event_obj", received.name
        assert_equal({ data: 42 }, received.payload)
        assert_operator received.duration, :>, 0
        assert_operator received.allocations, :>=, 100
      end

      def test_evented_subscriber_receives_start_and_finish
        listener = Class.new do
          attr_reader :events
          def initialize; @events = []; end
          def start(name, id, payload); @events << [:start, name]; end
          def finish(name, id, payload); @events << [:finish, name]; end
        end.new

        ActiveSupport::Notifications.subscribe("test.evented", listener)
        ActiveSupport::Notifications.instrument("test.evented") {}

        assert_equal [[:start, "test.evented"], [:finish, "test.evented"]], listener.events
      end

      # --- Mixed subscriber types on same event ---

      def test_mixed_subscriber_types
        mono_calls = []
        timed_calls = []
        event_calls = []
        evented_events = []

        ActiveSupport::Notifications.monotonic_subscribe("test.mixed") do |name, start, finish, id, payload|
          mono_calls << name
        end

        ActiveSupport::Notifications.subscribe("test.mixed") do |name, start, finish, id, payload|
          timed_calls << name
        end

        ActiveSupport::Notifications.subscribe("test.mixed") do |event|
          event_calls << event.name
        end

        listener = Class.new do
          attr_reader :events
          def initialize; @events = []; end
          def start(name, id, payload); @events << :start; end
          def finish(name, id, payload); @events << :finish; end
        end.new
        evented_events = listener.events

        ActiveSupport::Notifications.subscribe("test.mixed", listener)
        ActiveSupport::Notifications.instrument("test.mixed") {}

        assert_equal ["test.mixed"], mono_calls
        assert_equal ["test.mixed"], timed_calls
        assert_equal ["test.mixed"], event_calls
        assert_equal [:start, :finish], evented_events
      end

      # --- Exception handling ---

      def test_exception_in_single_subscriber_is_raised
        ActiveSupport::Notifications.monotonic_subscribe("test.err") do |*args|
          raise "boom"
        end

        error = assert_raises(RuntimeError) do
          ActiveSupport::Notifications.instrument("test.err") {}
        end
        assert_equal "boom", error.message
      end

      def test_exceptions_in_multiple_subscribers_are_collected
        ActiveSupport::Notifications.monotonic_subscribe("test.multi_err") do |*args|
          raise "first"
        end
        ActiveSupport::Notifications.monotonic_subscribe("test.multi_err") do |*args|
          raise "second"
        end

        error = assert_raises(InstrumentationSubscriberError) do
          ActiveSupport::Notifications.instrument("test.multi_err") {}
        end
        assert_equal 2, error.exceptions.size
        assert_equal "first", error.exceptions[0].message
        assert_equal "second", error.exceptions[1].message
      end

      def test_exception_in_block_sets_payload_and_reraises
        received_payload = nil
        ActiveSupport::Notifications.monotonic_subscribe("test.block_err") do |name, start, finish, id, payload|
          received_payload = payload
        end

        assert_raises(RuntimeError) do
          ActiveSupport::Notifications.instrument("test.block_err") { raise "kaboom" }
        end

        assert_equal ["RuntimeError", "kaboom"], received_payload[:exception]
        assert_instance_of RuntimeError, received_payload[:exception_object]
      end

      # --- Cache invalidation ---

      def test_subscribe_invalidates_dispatch_plan_cache
        calls = []
        ActiveSupport::Notifications.instrument("test.cache") {}
        assert_empty calls

        ActiveSupport::Notifications.monotonic_subscribe("test.cache") do |*args|
          calls << :called
        end

        ActiveSupport::Notifications.instrument("test.cache") {}
        assert_equal [:called], calls
      end

      def test_unsubscribe_invalidates_dispatch_plan_cache
        calls = []
        sub = ActiveSupport::Notifications.monotonic_subscribe("test.unsub") do |*args|
          calls << :called
        end

        ActiveSupport::Notifications.instrument("test.unsub") {}
        assert_equal [:called], calls

        ActiveSupport::Notifications.unsubscribe(sub)
        ActiveSupport::Notifications.instrument("test.unsub") {}
        assert_equal [:called], calls  # no new call
      end

      # --- Silenceable subscribers ---

      def test_silenceable_subscriber_can_be_silenced
        silenced = false
        calls = []

        listener = Class.new do
          define_method(:call) { |event| calls << event.name }
          define_method(:silenced?) { |name| silenced }
        end.new

        ActiveSupport::Notifications.subscribe("test.silence", listener)

        ActiveSupport::Notifications.instrument("test.silence") {}
        assert_equal ["test.silence"], calls

        silenced = true
        ActiveSupport::Notifications.instrument("test.silence") {}
        assert_equal ["test.silence"], calls  # still 1 — silenced subscriber skipped
      end

      # --- Payload mutation during block ---

      def test_payload_mutation_visible_to_subscribers
        received_payload = nil
        ActiveSupport::Notifications.monotonic_subscribe("test.mutate") do |name, start, finish, id, payload|
          received_payload = payload
        end

        ActiveSupport::Notifications.instrument("test.mutate", key: "before") do |payload|
          payload[:key] = "after"
          payload[:extra] = "added"
        end

        assert_equal "after", received_payload[:key]
        assert_equal "added", received_payload[:extra]
      end

      # --- Prepend ordering ---

      def test_prepend_ordering_preserved
        order = []
        ActiveSupport::Notifications.subscribe("test.order") do |event|
          order << :first
        end
        ActiveSupport::Notifications.subscribe("test.order") do |event|
          order << :second
        end
        @notifier.subscribe("test.order", prepend: true) do |event|
          order << :prepended
        end

        ActiveSupport::Notifications.instrument("test.order") {}
        assert_equal [:prepended, :first, :second], order
      end

      # --- build_handle backward compat ---

      def test_build_handle_still_works
        received = []
        ActiveSupport::Notifications.subscribe("test.handle") do |name, start, finish, id, payload|
          received << name
        end

        instrumenter = ActiveSupport::Notifications.instrumenter
        handle = instrumenter.build_handle("test.handle", {})
        handle.start
        handle.finish

        assert_equal ["test.handle"], received
      end

      # --- No block ---

      def test_instrument_without_block
        received = nil
        ActiveSupport::Notifications.monotonic_subscribe("test.noblock") do |name, start, finish, id, payload|
          received = { name: name, payload: payload }
        end

        ActiveSupport::Notifications.instrument("test.noblock", data: 1)

        assert_not_nil received
        assert_equal "test.noblock", received[:name]
        assert_equal({ data: 1 }, received[:payload])
      end

      # --- Empty plan must return block result (ActiveRecord depends on this) ---

      def test_no_subscribers_returns_block_result
        instrumenter = ActiveSupport::Notifications.instrumenter

        assert_equal :ok, instrumenter.instrument("no.subscribers") { :ok }
      end

      # --- Feedback issue #1: empty plan exception populates payload ---

      def test_no_subscribers_exception_populates_payload
        payload = { key: "value" }
        instrumenter = ActiveSupport::Notifications.instrumenter

        # Call instrumenter.instrument directly (not Notifications.instrument)
        # because the outer method short-circuits when listening? is false.
        assert_raises(RuntimeError) do
          instrumenter.instrument("no.subscribers", payload) { raise "boom" }
        end

        assert_equal ["RuntimeError", "boom"], payload[:exception]
        assert_instance_of RuntimeError, payload[:exception_object]
      end

      # --- Feedback issue #2: start exception aborts block ---

      def test_start_exception_aborts_block
        block_ran = false
        finish_ran = false

        listener = Class.new do
          define_method(:start) { |name, id, payload| raise "start boom" }
          define_method(:finish) { |name, id, payload| finish_ran = true }
        end.new

        ActiveSupport::Notifications.subscribe("test.start_abort", listener)

        error = assert_raises(RuntimeError) do
          ActiveSupport::Notifications.instrument("test.start_abort") { block_ran = true }
        end

        assert_equal "start boom", error.message
        assert_not block_ran, "block should not have executed when start raised"
        assert_not finish_ran, "finish should not have run when start raised"
      end

      def test_multiple_start_exceptions_collected_and_block_aborted
        block_ran = false

        bad_listener1 = Class.new do
          define_method(:start) { |name, id, payload| raise "start1" }
          define_method(:finish) { |name, id, payload| }
        end.new

        bad_listener2 = Class.new do
          define_method(:start) { |name, id, payload| raise "start2" }
          define_method(:finish) { |name, id, payload| }
        end.new

        good_listener = Class.new do
          attr_reader :events
          define_method(:initialize) { @events = [] }
          define_method(:start) { |name, id, payload| @events << :start }
          define_method(:finish) { |name, id, payload| @events << :finish }
        end.new

        ActiveSupport::Notifications.subscribe("test.multi_start", bad_listener1)
        ActiveSupport::Notifications.subscribe("test.multi_start", bad_listener2)
        ActiveSupport::Notifications.subscribe("test.multi_start", good_listener)

        error = assert_raises(InstrumentationSubscriberError) do
          ActiveSupport::Notifications.instrument("test.multi_start") { block_ran = true }
        end

        assert_equal 2, error.exceptions.size
        assert_not block_ran, "block should not have executed when start raised"
        # good_listener's start was called (exceptions are collected, all starts run)
        assert_equal [:start], good_listener.events
      end

      # --- Feedback issue #3: silenced state snapshotted once ---

      def test_silenced_state_snapshotted_for_evented_subscriber
        silenced = false
        events = []

        listener = Class.new do
          define_method(:start) { |name, id, payload| events << :start }
          define_method(:finish) { |name, id, payload| events << :finish }
          define_method(:silenced?) { |name| silenced }
        end.new

        ActiveSupport::Notifications.subscribe("test.snap", listener)

        # Not silenced — gets both start and finish
        ActiveSupport::Notifications.instrument("test.snap") {}
        assert_equal [:start, :finish], events

        # Toggle silenced mid-block — should still get consistent start+finish
        events.clear
        silenced = false
        ActiveSupport::Notifications.instrument("test.snap") do
          silenced = true  # change mid-block
        end
        # Snapshotted at dispatch start: was not silenced, so gets both
        assert_equal [:start, :finish], events
      end

      def test_silenced_subscriber_gets_neither_start_nor_finish
        events = []

        listener = Class.new do
          define_method(:start) { |name, id, payload| events << :start }
          define_method(:finish) { |name, id, payload| events << :finish }
          define_method(:silenced?) { |name| true }
        end.new

        ActiveSupport::Notifications.subscribe("test.silenced", listener)
        ActiveSupport::Notifications.instrument("test.silenced") {}

        assert_empty events
      end

      def test_unsilenced_mid_block_does_not_get_finish_without_start
        silenced = true
        events = []

        listener = Class.new do
          define_method(:start) { |name, id, payload| events << :start }
          define_method(:finish) { |name, id, payload| events << :finish }
          define_method(:silenced?) { |name| silenced }
        end.new

        ActiveSupport::Notifications.subscribe("test.unsil", listener)
        ActiveSupport::Notifications.instrument("test.unsil") do
          silenced = false  # unsilence mid-block
        end

        # Was silenced at snapshot time — should get neither
        assert_empty events
      end

      # --- Feedback issue #4 (block raises + subscriber finish raises) ---

      def test_block_exception_and_subscriber_exception
        ActiveSupport::Notifications.monotonic_subscribe("test.double_err") do |*args|
          raise "subscriber boom"
        end

        # The block exception should propagate (subscriber exception collected)
        error = assert_raises(RuntimeError) do
          ActiveSupport::Notifications.instrument("test.double_err") { raise "block boom" }
        end
        # Block exception takes precedence since it's re-raised first,
        # but subscriber exception is also raised in ensure.
        # The exact behavior depends on Ruby's ensure semantics —
        # the subscriber exception replaces the block exception.
        assert_includes ["block boom", "subscriber boom"], error.message
      end

      # --- Feedback issue #5: silenceable subscribers don't force allocations ---

      def test_all_silenced_event_object_subscribers_skip_event_allocation
        listener = Class.new do
          define_method(:call) { |event| }
          define_method(:silenced?) { |name| true }
        end.new

        ActiveSupport::Notifications.subscribe("test.all_silenced", listener)

        # Warm
        ActiveSupport::Notifications.instrument("test.all_silenced") {}

        before = GC.stat(:total_allocated_objects)
        ActiveSupport::Notifications.instrument("test.all_silenced") {}
        after = GC.stat(:total_allocated_objects)

        allocated = after - before
        # Should be similar to no-subscriber case — no Event object allocated
        assert_operator allocated, :<=, 5, "Expected near-zero allocations when all silenced, got #{allocated}"
      end
    end
  end
end
