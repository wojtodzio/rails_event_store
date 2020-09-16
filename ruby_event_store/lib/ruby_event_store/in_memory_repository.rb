# frozen_string_literal: true

require 'ostruct'
module RubyEventStore
  class InMemoryRepository

    def initialize(serializer: NULL)
      @serializer = serializer
      @streams = Hash.new
      @mutex = Mutex.new
      @global = Array.new
    end

    def append_to_stream(records, stream, expected_version)
      add_to_stream(Array(records).map{|record| record.serialize(serializer)},
        expected_version, stream, true)
    end

    def link_to_stream(event_ids, stream, expected_version)
      serialized_records = Array(event_ids).map {|eid| read_event(eid)}
      add_to_stream(serialized_records, expected_version, stream, nil)
    end

    def delete_stream(stream)
      streams.delete(stream.name)
    end

    def has_event?(event_id)
       global.any?{ |item| item.event_id.eql?(event_id) }
    end

    def last_stream_event(stream)
      serialized_records_of_stream(stream.name).last&.deserialize(serializer)
    end

    def read(spec)
      serialized_records = read_scope(spec)
      if spec.batched?
        batch_reader = ->(offset, limit) do
          serialized_records
            .drop(offset)
            .take(limit)
            .map{|serialized_record| serialized_record.deserialize(serializer) }
        end
        BatchEnumerator.new(spec.batch_size, serialized_records.size, batch_reader).each
      elsif spec.first?
        serialized_records.first&.deserialize(serializer)
      elsif spec.last?
        serialized_records.last&.deserialize(serializer)
      else
        Enumerator.new do |y|
          serialized_records.each do |serialized_record|
            y << serialized_record.deserialize(serializer)
          end
        end
      end
    end

    def count(spec)
      read_scope(spec).count
    end

    def update_messages(records)
      records.each do |record|
        location = global.index{|m| record.event_id.eql?(m.event_id)} or raise EventNotFound.new(record.event_id)
        serialized_record =
          Record.new(
            event_id:   record.event_id,
            event_type: record.event_type,
            data:       record.data,
            metadata:   record.metadata,
            timestamp:  Time.iso8601(global.fetch(location).timestamp),
            valid_at:   record.valid_at,
          ).serialize(serializer)
        global[location] = serialized_record
        streams.values.each do |str|
          location = str.index{|m| record.event_id.eql?(m.event_id)}
          str[location] = serialized_record if location
        end
      end
    end

    def streams_of(event_id)
      streams.select do |_, serialized_records_of_stream|
        serialized_records_of_stream.any? { |event| event.event_id.eql?(event_id) }
      end.map { |name, | Stream.new(name) }
    end

    private
    def read_scope(spec)
      serialized_records = spec.stream.global? ? global : serialized_records_of_stream(spec.stream.name)
      serialized_records = serialized_records.select{|e| spec.with_ids.any?{|x| x.eql?(e.event_id)}} if spec.with_ids?
      serialized_records = serialized_records.select{|e| spec.with_types.any?{|x| x.eql?(e.event_type)}} if spec.with_types?
      serialized_records = serialized_records.reverse if spec.backward?
      serialized_records = serialized_records.drop(index_of(serialized_records, spec.start) + 1) if spec.start
      serialized_records = serialized_records.take(index_of(serialized_records, spec.stop)) if spec.stop
      serialized_records = serialized_records[0...spec.limit] if spec.limit?
      serialized_records
    end

    def read_event(event_id)
      global.find {|e| event_id.eql?(e.event_id)} or raise EventNotFound.new(event_id)
    end

    def serialized_records_of_stream(name)
      streams.fetch(name, Array.new)
    end

    def add_to_stream(serialized_records, expected_version, stream, include_global)
      append_with_synchronize(serialized_records, expected_version, stream, include_global)
    end

    def last_stream_version(stream)
      serialized_records_of_stream(stream.name).size - 1
    end

    def append_with_synchronize(serialized_records, expected_version, stream, include_global)
      resolved_version = expected_version.resolve_for(stream, method(:last_stream_version))

      # expected_version :auto assumes external lock is used
      # which makes reading stream before writing safe.
      #
      # To emulate potential concurrency issues of :auto strategy without
      # such external lock we use Thread.pass to make race
      # conditions more likely. And we only use mutex.synchronize for writing
      # not for the whole read+write algorithm.
      Thread.pass
      mutex.synchronize do
        resolved_version = last_stream_version(stream) if expected_version.any?
        append(serialized_records, resolved_version, stream, include_global)
      end
    end

    def append(serialized_records, resolved_version, stream, include_global)
      serialized_records_of_stream_ = serialized_records_of_stream(stream.name)
      raise WrongExpectedEventVersion unless last_stream_version(stream).equal?(resolved_version)

      serialized_records.each do |serialized_record|
        raise EventDuplicatedInStream if serialized_records_of_stream_.any? {|ev| ev.event_id.eql?(serialized_record.event_id)}
        if include_global
          raise EventDuplicatedInStream if has_event?(serialized_record.event_id)
          global.push(serialized_record)
        end
        serialized_records_of_stream_.push(serialized_record)
      end
      streams[stream.name] = serialized_records_of_stream_
      self
    end

    def index_of(source, event_id)
      source.index {|item| item.event_id.eql?(event_id)}
    end

    attr_reader :streams, :mutex, :global, :serializer
  end
end
