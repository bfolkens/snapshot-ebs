require 'logger'
require 'rubygems'
require 'right_aws'
require 'net/http'
require 'lvm'
require 'active_support'

require File.dirname(__FILE__) + '/silence_net_http'


def lock_lvm(options = {}, &block)
	lvm_devs = `/sbin/dmsetup ls`.split("\n").map {|line| line.gsub /^(.+?)\t.*/, '\1' }
	lvm_devs.each do |lvmdev|
		$logger.info "Suspending LVM device #{lvmdev}"
		$logger.debug `/sbin/dmsetup -v suspend /dev/mapper/#{lvmdev}` unless options[:dry_run]
	end

	yield
ensure
	# Make SURE these are resumed
	lvm_devs.each do |lvmdev|
		$logger.info "Resuming LVM device #{lvmdev}"
		$logger.debug `/sbin/dmsetup -v resume /dev/mapper/#{lvmdev}` unless options[:dry_run]
	end
end

def difference_in_time(from, to)
	distance_in_minutes = (((to - from).abs)/60).round
	distance_in_seconds = ((to - from).abs).round

	case distance_in_minutes
		when 0..1439 # 0-23.9 hours
			:hourly
		when 1440..10079 # 1-6.99 days
			:daily
		when 10080..43199 # 7-29.99 days
			:weekly
		when 43200..1051199 # 30-364.99 days
			:monthly
		else
			nil
	end
end

def sort_snapshots(ec2_snapshots, ec2_volume, now = Time.now)
	snapshots = { :hourly => [], :daily => [], :weekly => [], :monthly => [] }

	# Iterate through the snapshots NEWEST FIRST!
	ec2_snapshots.sort {|a, b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snap|
		# Make sure we're dealing with this volume
		next unless ec2_volume[:aws_id] == snap[:aws_volume_id]

		# Check dates and determine what "level" we're looking at
		level = difference_in_time(snap[:aws_started_at], now)
		snapshots[level] << snap
	end

	return snapshots
end

