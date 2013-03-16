require 'rubygems'
require 'logger'
gem 'right_aws', '~>3.0.4'
require 'right_aws'
require 'net/http'

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

	# Reject those that don't match this volume
	this_volume_snaps = ec2_snapshots.reject {|snap| ec2_volume[:aws_id] != snap[:aws_volume_id] }

	# Sort the snapshots newest first
	this_volume_snaps.sort! {|a, b| Time.parse(b[:aws_started_at]) <=> Time.parse(a[:aws_started_at]) }

	# Check dates and form "levels"
	last_timestamp = now
	this_volume_snaps.each do |snap|
		level = difference_in_time(Time.parse(snap[:aws_started_at]), last_timestamp)
		last_timestamp = Time.parse(snap[:aws_started_at])
		snapshots[level] << snap
	end

	return snapshots
end

