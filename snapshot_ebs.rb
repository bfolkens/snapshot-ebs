#!/usr/bin/env ruby

require "rubygems"
require 'logger'
require 'optparse'
require 'socket'
require 'pathname'
require File.dirname(Pathname.new(__FILE__).realpath) + '/lib/snapshot_ebs'


#
# Main application
#
$logger = Logger.new(STDOUT)
$logger.datetime_format = "%Y-%m-%d %H:%M:%S"
$logger.level = Logger::DEBUG

options = {}
parser = OptionParser.new do |p|
	p.banner = 'Usage: snapshot_ebs.rb [options]'
	p.separator ''
	p.separator 'Specific options:'

	p.on("-a", "--access-key USER", "The user's AWS access key ID.") {|aki| options[:aws_access_key_id] = aki }
	p.on("-s", "--secret-key PASSWORD", "The user's AWS secret access key.") {|sak| options[:aws_secret_access_key] = sak }
	p.on("-n", "--dry-run", "Don't perform any actions.") { options[:dry_run] = true }

	p.on_tail("-h", "--help", "Show this message") do
		puts p
		exit
	end
	p.parse!(ARGV) rescue puts(p)
end

# Check for config file too
CONFIG_FILE = "#{ENV['HOME']}/.snapshot_ebs_rc"
if File.exists?(CONFIG_FILE)
	yaml_config = YAML::load(File.open(CONFIG_FILE))
	options.reverse_merge! yaml_config
end

# Check required options
if !options.key?(:aws_access_key_id) or
	!options.key?(:aws_secret_access_key)
		puts parser
		exit 1
end

$logger.info "DRY-RUN: No destructive commands will be run" if options[:dry_run]

# Determine our instance ID
instance_id = Net::HTTP.get('169.254.169.254', '/latest/meta-data/instance-id')

# Create a connection to AWS
ec2 = RightAws::Ec2.new(options[:aws_access_key_id], options[:aws_secret_access_key], :logger => $logger)

# Locate the volume(s) attached to this instance
volumes = ec2.describe_volumes.reject {|vol| vol[:aws_instance_id] != instance_id }
if volumes.nil? or volumes.empty?
	$logger.error "Error: Unable to find volumes attached to this instance"
	exit 1
end

# Suspend/Resume all LVM devs
lock_lvm options do
	# Snapshot all EBS vols included by lvm volumes
	volumes.each do |vol|
		$logger.info "Calling create-snapshot for #{vol[:aws_id]} as '#{Socket.gethostname}:#{vol[:aws_device]}'"
		unless options[:dry_run]
			begin
				result = ec2.create_snapshot(vol[:aws_id], "#{Socket.gethostname}:#{vol[:aws_device]}")
				$logger.info "Created snapshot #{result[:aws_id]} for #{result[:aws_volume_id]}"
			rescue => e
				puts e.message
			end
		end
	end
end

# Delete old snapshots
MAX = { :hourly => 3, :daily => 7, :weekly => 5, :monthly => 6 }
volumes.each do |vol|
	snapshots = sort_snapshots(ec2.describe_snapshots, vol)
	$logger.debug "Totals (#{vol[:aws_id]} #{vol[:aws_device]}): #{snapshots[:hourly].size} hourly, #{snapshots[:daily].size} daily, #{snapshots[:weekly].size} weekly, #{snapshots[:monthly].size} monthly"

	snapshots.each_pair do |level, snaps|
		snap_count = snaps.size
		snaps.each_with_index do |snap, index|
			$logger.info "Snapshot #{snap[:aws_id]}: #{snap[:aws_started_at].inspect} (#{level}), #{snap[:aws_status]} #{snap[:aws_progress]}"

			# Delete if we've exceeded our level max
			# OR if there are consecutive snapshots that are not the same as the current level (two daily snapshots a few hours apart)
			next_snap = snaps[index + 1]
			if index + 1 > MAX[level] or (next_snap and difference_in_time(snap[:aws_started_at], next_snap[:aws_started_at]) != level)
				begin
					$logger.info "Removing expired EBS snapshot #{snap[:aws_id]}"
					ec2.delete_snapshot(snap[:aws_id]) unless options[:dry_run]
				rescue => e
					puts e.message
				end
			end
		end
	end
end

