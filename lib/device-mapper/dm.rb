require 'lib/log'
require 'lib/prelude'
require 'lib/process'
require 'lib/utils'
require 'lib/queue_limits'

#----------------------------------------------------------------

module DM
  class Target
    attr_accessor :type, :args, :sector_count

    def initialize(t, sector_count, *args)
      @type = t
      @sector_count = sector_count
      @args = args
    end
  end

  class ErrorTarget < Target
    def initialize(sector_count)
      super('error', sector_count)
    end
  end

  class LinearTarget < Target
    def initialize(sector_count, dev, offset)
      super('linear', sector_count, dev, offset)
    end
  end

  class StripeTarget < Target
    def initialize(sector_count, chunk_size, *pairs)
      super('striped', sector_count, chunk_size, *(pairs.flatten))
    end
  end

  class ThinPoolTarget < Target
    attr_accessor :metadata_dev

    def initialize(sector_count, metadata_dev, data_dev, block_size, low_water_mark,
                   zero = true, discard = true, discard_pass = true, read_only = false)
      extra_opts = Array.new

      extra_opts.instance_eval do
        push :skip_block_zeroing unless zero
        push :ignore_discard unless discard
        push :no_discard_passdown unless discard_pass
        push :read_only if read_only
      end

      super('thin-pool', sector_count, metadata_dev, data_dev, block_size, low_water_mark, extra_opts.length, *extra_opts)
      @metadata_dev = metadata_dev
    end

    def post_remove_check
      ProcessControl.run("thin_check #{@metadata_dev}")
    end
  end

  class ThinTarget < Target
    def initialize(sector_count, pool, id, origin = nil)
      if origin
        super('thin', sector_count, pool, id, origin)
      else
        super('thin', sector_count, pool, id)
      end
    end
  end

  class CacheTarget < Target
    def initialize(sector_count, metadata_dev, cache_dev, origin_dev, block_size, features,
                   policy, keys)
      args = [metadata_dev, cache_dev, origin_dev, block_size, features.size] +
        features.map {|f| f.to_s} + [policy, 2 * keys.size] + keys.map {|k, v| [k.to_s.sub(/_\d$/, "")] + [v.to_s]}

      super('cache', sector_count, *args)
    end
  end

  class FakeDiscardTarget < Target
    def initialize(sector_count, dev, offset, granularity, max_discard,
                   no_discard_support = false, discard_zeroes = false)
      extra_opts = Array.new

      extra_opts.instance_eval do
        push :no_discard_support if no_discard_support
        push :discard_zeroes_data if discard_zeroes
      end

      super('fake-discard', sector_count, dev, offset, granularity,
            max_discard, extra_opts.length, *extra_opts)
    end
  end

  #----------------------------------------------------------------

  class Table
    attr_accessor :targets

    def initialize(*targets)
      @targets = targets
    end

    def size
      @targets.inject(0) {|tot, t| tot += t.sector_count}
    end

    def to_s()
      start_sector = 0

      @targets.map do |t|
        r = "#{start_sector} #{t.sector_count} #{t.type} #{t.args.join(' ')}"
        start_sector += t.sector_count
        r
      end.join("\n")
    end

    def to_embed_
      start_sector = 0

      @targets.map do |t|
        r = "#{start_sector} #{t.sector_count} #{t.type} #{t.args.join(' ')}"
        start_sector += t.sector_count
        r
      end.join("; ")
    end

    def to_embed
      "<<table:#{to_embed_}>>"
    end
  end

  # This hands off most of it's work to DMInterface
  # FIXME: not true
  class DMDev
    attr_reader :name, :interface, :active_table

    def initialize(name, interface)
      @name = name
      @interface = interface
    end

    def path()
      "/dev/mapper/#{name}"
    end

    def load(table)
      Utils::with_temp_file('dm-table') do |f|
        debug "writing table: #{table.to_embed}"
        f.puts table.to_s
        f.flush
        ProcessControl.run("dmsetup load #{@name} #{f.path}")
      end

      # FIXME: not active yet!
      @active_table = table
    end

    def suspend
      @interface.suspend(path)
    end

    def resume
      @interface.resume(path)
    end

    def pause(&block)
      suspend
      bracket_(method(:resume), &block)
    end

    def remove
      @interface.remove(path)
    end

    def message(sector, *args)
      @interface.message(path, sector, *args)
    end

    def status
      @interface.status(path)
    end

    def table
      @interface.table(path)
    end

    def info
      @interface.info(path)
    end

    def dm_name
      m = /Major, minor:\s*\d+, (\d+)/.match(info)
      raise "Couldn't find minor number for dm device in info" unless m

      "dm-#{m[1]}"
    end

    def event_nr
      output = @interface.status(path, '-v')
      m = output.match(/Event number:[ \t]*([0-9]+)/)
      if m.nil?
        raise "Couldn't find event number for dm device"
      end

      m[1].to_i
    end

    def event_tracker(&condition)
      DMEventTracker.new(event_nr, self)
    end

    #--------------------------------
    # FIXME: the rest of these methods should go elsewhere
    def post_remove_check
      @active_table.targets.each do |target|
        if target.public_methods.member?('post_remove_check')
          target.post_remove_check
        end
      end
    end

    def to_s
      path
    end

    # discards bytes delimited by b (begin, inclusive) and e (end,
    # non-inclusive).  b and e are given in 512 byte sectors.
    BLKDISCARD = 4727

    def discard(b, e)
      File.open(path, File::RDWR | File::NONBLOCK) do |ctrl|
        ctrl.ioctl(BLKDISCARD, [b * 512, e * 512].pack('QQ'))
      end
    end

    def queue_limits
      QueueLimits.new(dm_name)
    end
  end

  class DMEventTracker
    attr_reader :event_nr, :device

    def initialize(n, d)
      @event_nr = n
      @device = d
    end

    # Wait for an event _since_ this one.  Updates event nr to reflect
    # the new number.
    def wait(*args, &condition)
      until condition.call(*args)
        ProcessControl.run("dmsetup wait #{@device.name} #{@event_nr}")
        @event_nr = @device.event_nr
      end
    end
  end

  class DMInterface
    def suspend(path)
      ProcessControl.run("dmsetup suspend #{path}")
    end

    def resume(path)
      ProcessControl.run("dmsetup resume #{path}")
    end

    def remove(path)
      # FIXME: lift this retry?
      Utils.retry_if_fails(5.0) do
        if File.exists?(path)
          ProcessControl.run("dmsetup remove #{path}")
        end
      end
    end

    def message(name, sector, *args)
      ProcessControl.run("dmsetup message #{path} #{sector} #{args.join(' ')}")
    end

    def status(path, *args)
      ProcessControl.run("dmsetup status #{args} #{path}")
    end

    def table(path)
      ProcessControl.run("dmsetup table #{path}")
    end

    def info(path)
      ProcessControl.run("dmsetup info #{path}")
    end

    #--------------------------------
    # FIXME: move these to a mixin module

    def with_dev(table = nil, &block)
      bracket(create(table),
              lambda {|dev| dev.remove; dev.post_remove_check},
              &block)
    end

    def with_devs(*tables, &block)
      release = lambda do |devs|
        devs.each do |dev|
          begin
            dev.remove
            dev.post_remove_check
          rescue
          end
        end
      end

      bracket(Array.new, release) do |devs|
        tables.each do |table|
          devs << create(table)
        end

        block.call(*devs)
      end
    end

    def mk_dev(table = nil)
      create(table)
    end

    private
    def create(table = nil)
      name = create_name
      ProcessControl.run("dmsetup create #{name} --notable")
      protect_(lambda {ProcessControl.run("dmsetup remove #{name}")}) do
        dev = DMDev.new(name, self)
        unless table.nil?
          dev.load table
          dev.resume
        end
        dev
      end
    end

    def create_name()
      # fixme: check this device doesn't already exist
      "test-dev-#{rand(1000000)}"
    end
  end
end

#----------------------------------------------------------------
