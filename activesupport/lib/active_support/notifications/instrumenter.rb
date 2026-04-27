# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require "securerandom"

module ActiveSupport
  module Notifications
    # Instrumenters are stored in a thread local.
    class Instrumenter
      attr_reader :id

      def initialize(notifier)
        unless notifier.respond_to?(:build_handle)
          notifier = LegacyHandle::Wrapper.new(notifier)
        end

        @id       = unique_id
        @notifier = notifier
        @use_dispatch_plan = notifier.respond_to?(:dispatch_plan_for)
      end

      class LegacyHandle # :nodoc:
        class Wrapper # :nodoc:
          def initialize(notifier)
            @notifier = notifier
          end

          def build_handle(name, id, payload)
            LegacyHandle.new(@notifier, name, id, payload)
          end

          delegate :start, :finish, to: :@notifier
        end

        def initialize(notifier, name, id, payload)
          @notifier = notifier
          @name = name
          @id = id
          @payload = payload
        end

        def start
          @listener_state = @notifier.start @name, @id, @payload
        end

        def finish
          @notifier.finish(@name, @id, @payload, @listener_state)
        end
      end

      # Given a block, instrument it by measuring the time taken to execute
      # and publish it. Without a block, simply send a message via the
      # notifier. Notice that events get sent even if an error occurs in the
      # passed-in block.
      def instrument(name, payload = {})
        # Fast path: use the cached dispatch plan to avoid allocating
        # Handle, Group, and intermediate Array objects.
        if @use_dispatch_plan
          dispatch_inline(name, payload) { yield payload if block_given? }
        else
          handle = build_handle(name, payload)
          handle.start
          begin
            yield payload if block_given?
          rescue Exception => e
            payload[:exception] = [e.class.name, e.message]
            payload[:exception_object] = e
            raise e
          ensure
            handle.finish
          end
        end
      end

      # Returns a "handle" for an event with the given +name+ and +payload+.
      #
      # #start and #finish must each be called exactly once on the returned object.
      #
      # Where possible, it's best to use #instrument, which will record the
      # start and finish of the event and correctly handle any exceptions.
      # +build_handle+ is a low-level API intended for cases where using
      # +instrument+ isn't possible.
      #
      # See ActiveSupport::Notifications::Fanout::Handle.
      def build_handle(name, payload)
        @notifier.build_handle(name, @id, payload)
      end

      def new_event(name, payload = {}) # :nodoc:
        Event.new(name, nil, nil, @id, payload)
      end

      # Send a start notification with +name+ and +payload+.
      def start(name, payload)
        @notifier.start name, @id, payload
      end

      # Send a finish notification with +name+ and +payload+.
      def finish(name, payload)
        @notifier.finish name, @id, payload
      end

      def finish_with_state(listeners_state, name, payload)
        @notifier.finish name, @id, payload, listeners_state
      end

      private
        def unique_id
          SecureRandom.hex(10)
        end

        def dispatch_inline(name, payload)
          plan = @notifier.dispatch_plan_for(name)

          if plan.empty?
            begin
              return yield
            rescue Exception => e
              payload[:exception] = [e.class.name, e.message]
              payload[:exception_object] = e
              raise e
            end
          end

          id = @id

          # Fix #3: Snapshot silenced state once so start/finish see the
          # same set of active subscribers. Also solves #5 — if all
          # silenceable subscribers are silenced, we skip allocations.
          active_monotonic = plan.silenceable_monotonic_timed ? plan.silenceable_monotonic_timed.reject { |s| s.silenced?(name) } : nil
          active_monotonic = nil if active_monotonic&.empty?
          active_timed = plan.silenceable_timed ? plan.silenceable_timed.reject { |s| s.silenced?(name) } : nil
          active_timed = nil if active_timed&.empty?
          active_evented = plan.silenceable_evented ? plan.silenceable_evented.reject { |s| s.silenced?(name) } : nil
          active_evented = nil if active_evented&.empty?
          active_event_object = plan.silenceable_event_object ? plan.silenceable_event_object.reject { |s| s.silenced?(name) } : nil
          active_event_object = nil if active_event_object&.empty?

          # Fix #2: Start-phase exceptions must abort the block.
          # Collect all start exceptions, then raise before yield.
          exceptions = nil

          if plan.evented
            plan.evented.each do |s|
              s.start(name, id, payload)
            rescue Exception => e
              (exceptions ||= []) << e
            end
          end

          if active_evented
            active_evented.each do |s|
              s.start(name, id, payload)
            rescue Exception => e
              (exceptions ||= []) << e
            end
          end

          event = nil
          needs_event = plan.event_object || active_event_object
          if needs_event
            event = Event.new(name, nil, nil, id, payload)
            event.start!
          end

          needs_monotonic = plan.monotonic_timed || active_monotonic
          needs_timed = plan.timed || active_timed
          monotonic_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) if needs_monotonic
          timed_start = Time.now if needs_timed

          # If any start callback raised, abort — don't run the block or finish.
          if exceptions
            raise_exceptions(exceptions)
          end

          begin
            yield
          rescue Exception => e
            payload[:exception] = [e.class.name, e.message]
            payload[:exception_object] = e
            raise e
          ensure
            # Finish phase — dispatch to each type directly
            if plan.monotonic_timed
              monotonic_finish = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              plan.monotonic_timed.each do |s|
                s.call(name, monotonic_start, monotonic_finish, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if active_monotonic
              monotonic_finish ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
              active_monotonic.each do |s|
                s.call(name, monotonic_start, monotonic_finish, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if plan.timed
              timed_finish = Time.now
              plan.timed.each do |s|
                s.call(name, timed_start, timed_finish, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if active_timed
              timed_finish ||= Time.now
              active_timed.each do |s|
                s.call(name, timed_start, timed_finish, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if plan.evented
              plan.evented.each do |s|
                s.finish(name, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if active_evented
              active_evented.each do |s|
                s.finish(name, id, payload)
              rescue Exception => e
                (exceptions ||= []) << e
              end
            end

            if event
              event.payload = payload
              event.finish!
              if plan.event_object
                plan.event_object.each do |s|
                  s.call(event)
                rescue Exception => e
                  (exceptions ||= []) << e
                end
              end
              if active_event_object
                active_event_object.each do |s|
                  s.call(event)
                rescue Exception => e
                  (exceptions ||= []) << e
                end
              end
            end

            raise_exceptions(exceptions) if exceptions
          end
        end

        def raise_exceptions(exceptions)
          exceptions = exceptions.flat_map do |exception|
            exception.is_a?(Notifications::InstrumentationSubscriberError) ? exception.exceptions : [exception]
          end
          if exceptions.size == 1
            raise exceptions.first
          else
            raise Notifications::InstrumentationSubscriberError.new(exceptions), cause: exceptions.first
          end
        end
    end

    class Event
      attr_reader :name, :transaction_id
      attr_accessor :payload

      def initialize(name, start, ending, transaction_id, payload)
        @name           = name
        @payload        = payload.dup
        @time           = start ? start.to_f * 1_000.0 : start
        @transaction_id = transaction_id
        @end            = ending ? ending.to_f * 1_000.0 : ending
        @cpu_time_start = 0.0
        @cpu_time_finish = 0.0
        @allocation_count_start = 0
        @allocation_count_finish = 0
        @gc_time_start = 0
        @gc_time_finish = 0
      end

      def time
        @time / 1000.0 if @time
      end

      def end
        @end / 1000.0 if @end
      end

      def record # :nodoc:
        start!
        begin
          yield payload if block_given?
        rescue Exception => e
          payload[:exception] = [e.class.name, e.message]
          payload[:exception_object] = e
          raise e
        ensure
          finish!
        end
      end

      # Record information at the time this event starts
      def start!
        @time = now
        @cpu_time_start = now_cpu
        @gc_time_start = now_gc
        @allocation_count_start = now_allocations
      end

      # Record information at the time this event finishes
      def finish!
        @cpu_time_finish = now_cpu
        @gc_time_finish = now_gc
        @end = now
        @allocation_count_finish = now_allocations
      end

      # Returns the CPU time (in milliseconds) passed between the call to
      # #start! and the call to #finish!.
      def cpu_time
        @cpu_time_finish - @cpu_time_start
      end

      # Returns the idle time (in milliseconds) passed between the call to
      # #start! and the call to #finish!.
      def idle_time
        diff = duration - cpu_time
        diff > 0.0 ? diff : 0.0
      end

      # Returns the number of allocations made between the call to #start! and
      # the call to #finish!.
      def allocations
        @allocation_count_finish - @allocation_count_start
      end

      # Returns the time spent in GC (in milliseconds) between the call to #start!
      # and the call to #finish!
      def gc_time
        (@gc_time_finish - @gc_time_start) / 1_000_000.0
      end

      # Returns the difference in milliseconds between when the execution of the
      # event started and when it ended.
      #
      #   ActiveSupport::Notifications.subscribe('wait') do |event|
      #     @event = event
      #   end
      #
      #   ActiveSupport::Notifications.instrument('wait') do
      #     sleep 1
      #   end
      #
      #   @event.duration # => 1000.138
      def duration
        @end - @time
      end

      private
        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        end

        begin
          Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :float_millisecond)

          def now_cpu
            Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :float_millisecond)
          end
        rescue
          def now_cpu
            0.0
          end
        end

        if GC.respond_to?(:total_time)
          def now_gc
            GC.total_time
          end
        else
          def now_gc
            0
          end
        end

        if GC.stat.key?(:total_allocated_objects)
          def now_allocations
            GC.stat(:total_allocated_objects)
          end
        else # Likely on JRuby, TruffleRuby
          def now_allocations
            0
          end
        end
    end
  end
end
