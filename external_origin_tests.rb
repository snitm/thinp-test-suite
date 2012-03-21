require 'config'
require 'lib/dm'
require 'lib/log'
require 'lib/utils'
require 'lib/fs'
require 'lib/tags'
require 'lib/thinp-test'
require 'lib/tvm'

#----------------------------------------------------------------

class ExternalOriginTests < ThinpTestCase
  include Tags
  include TinyVolumeManager
  include Utils

  def setup
    super
  end

  tag :thinp_target

  def test_origin_unchanged
    if (@volume_size % @data_block_size == 0)
    	@volume_size -= @data_block_size * 4 / 5
    end

    tvm = VM.new
    tvm.add_allocation_volume(@data_dev, 0, dev_size(@data_dev))

    data_dev_size = round_up(@volume_size, @data_block_size)
    tvm.add_volume(linear_vol('data', data_dev_size))
    tvm.add_volume(linear_vol('origin', @volume_size))

    with_devs(tvm.table('origin'),
              tvm.table('data')) do |origin, data|
      dt_device(origin)

      wipe_device(@metadata_dev, 8)
      pool_table = Table.new(ThinPool.new(data_dev_size, @metadata_dev, data, @data_block_size, 0))
      with_devs(pool_table) do |pool|
        with_new_thin(pool, @volume_size, 0, :origin => origin) do |thin|
          verify_device(thin, origin)

          dt_device(thin)
          verify_device(thin, origin)
        end
      end
    end
  end
end

#----------------------------------------------------------------
