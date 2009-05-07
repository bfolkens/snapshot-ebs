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
end
