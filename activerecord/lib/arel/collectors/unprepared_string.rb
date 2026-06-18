# frozen_string_literal: true

module Arel # :nodoc: all
  module Collectors
    # Combined collector for unprepared statements.
    # Merges SubstituteBinds + SQLString into a single object to avoid
    # two allocations and delegation overhead per query.
    class UnpreparedString
      attr_accessor :preparable, :retryable

      def initialize(quoter)
        @quoter = quoter
        @str = +""
        @bind_index = 1
      end

      def <<(str)
        @str << str
        self
      end

      def value
        @str
      end

      def add_bind(bind, &)
        bind = bind.value_for_database if bind.respond_to?(:value_for_database)
        @str << @quoter.quote(bind)
        self
      end

      def add_binds(binds, proc_for_binds = nil, &)
        @str << binds.map { |bind| @quoter.quote(bind) }.join(", ")
        self
      end
    end
  end
end
