require 'test/unit'
require File.dirname(__FILE__) + '/../lib/snapshot_ebs'

class TestSnapshotEBS < Test::Unit::TestCase
	def test_should_identify_difference_in_time
		assert_equal :hourly, difference_in_time(Time.now - (60 * 1), Time.now)
		assert_equal :hourly, difference_in_time(Time.now - (60 * 60 * 23), Time.now)

		assert_equal :daily, difference_in_time(Time.now - (60 * 60 * 24), Time.now)
		assert_equal :daily, difference_in_time(Time.now - (60 * 60 * 24 * 6), Time.now)

		assert_equal :weekly, difference_in_time(Time.now - (60 * 60 * 24 * 7), Time.now)
		assert_equal :weekly, difference_in_time(Time.now - (60 * 60 * 24 * 29), Time.now)

		assert_equal :monthly, difference_in_time(Time.now - (60 * 60 * 24 * 30), Time.now)
	end

	def test_should_calculate_distances
		list = %w(2012-08-23T19:00:52.000Z
							2012-08-23T11:00:08.000Z
							2012-08-23T03:00:08.000Z
							2012-08-22T03:00:08.000Z
							2012-08-21T03:00:07.000Z
							2012-08-20T03:00:07.000Z
							2012-08-19T03:00:06.000Z
							2012-08-18T03:00:07.000Z
							2012-08-11T03:00:06.000Z
							2012-08-04T03:00:06.000Z
							2012-07-28T03:00:06.000Z
							2012-07-21T03:00:05.000Z
							2012-06-15T11:00:06.000Z
							2012-05-11T03:00:05.000Z
							2012-04-05T19:00:05.000Z
							2012-03-01T19:00:05.000Z
							2012-01-26T19:00:03.000Z)

		list.map! {|timestamp| { :aws_started_at => timestamp, :aws_volume_id => 'testvol' } }

		# Check fresh distance
		snaps = sort_snapshots(list, { :aws_id => 'testvol' }, Time.parse('2012-08-23T23:00:52.000Z'))
		assert_equal 3, snaps[:hourly].size
		assert_equal 5, snaps[:daily].size
		assert_equal 4, snaps[:weekly].size
		assert_equal 5, snaps[:monthly].size

		# Check stale distance
		snaps = sort_snapshots(list, { :aws_id => 'testvol' }, Time.now)
		assert_equal 2, snaps[:hourly].size
		assert_equal 5, snaps[:daily].size
		assert_equal 4, snaps[:weekly].size
		assert_equal 6, snaps[:monthly].size
	end

end
