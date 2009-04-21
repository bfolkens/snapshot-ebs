#!/usr/bin/env ruby

require 'logger'
require 'optparse'
require 'rubygems'
require 'right_aws'
require 'net/http'
require 'lvm'
require 'active_support'


# hack to eliminate the SSL certificate verification notification
class Net::HTTP
	alias_method :old_initialize, :initialize
	def initialize(*args)
		old_initialize(*args)
		@ssl_context = OpenSSL::SSL::SSLContext.new
		@ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
end

def lock_lvm(options = {}, &block)
	lvm_devs = `/sbin/dmsetup ls`.split("\n").map {|line| line.gsub /^(.+?)\t.*/, '\1' }
	lvm_devs.each do |lvmdev|
		$logger.info "Suspending LVM device #{lvmdev}"
		$logger.debug `dmsetup -v suspend /dev/mapper/#{lvmdev}` unless options[:dry_run]
	end

	yield
ensure
	# Make SURE these are resumed
	lvm_devs.each do |lvmdev|
		$logger.info "Resuming LVM device #{lvmdev}"
		$logger.debug `dmsetup -v resume /dev/mapper/#{lvmdev}` unless options[:dry_run]
	end
end

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
		$logger.info "Calling create-snapshot for #{vol[:aws_id]}"
		unless options[:dry_run]
			result = ec2.create_snapshot(vol[:aws_id])
			$logger.info "Created snapshot #{result[:aws_id]} for #{result[:aws_volume_id]}"
		end
	end
end

# Delete old snapshots
MAX = { :hourly => 1, :daily => 6, :weekly => 3, :monthly => 6 }
monthly = weekly = daily = hourly = 0
# Iterate through the snapshots NEWEST FIRST!
ec2.describe_snapshots.sort {|a, b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snap|
	# Make sure we're dealing with this volume
	next unless volumes.map {|vol| vol[:aws_id] }.include?(snap[:aws_volume_id])

	# Check dates and determine what "level" we're looking at
	level = if snap[:aws_started_at] < snap[:aws_started_at].advance(:days => 1)
		hourly += 1
		:hourly
	elsif snap[:aws_started_at] > snap[:aws_started_at].advance(:days => 1) and snap[:aws_started_at] < snap[:aws_started_at].advance(:weeks => 1)
		daily += 1
		:daily
	elsif snap[:aws_started_at] > snap[:aws_started_at].advance(:weeks => 1) and snap[:aws_started_at] < snap[:aws_started_at].advance(:months => 1)
		weekly += 1
		:weekly
	elsif snap[:aws_started_at] > snap[:aws_started_at].advance(:months => 1) and snap[:aws_started_at] < snap[:aws_started_at].advance(:years => 1)
		monthly += 1
		:monthly
	end

	$logger.info "Snapshot #{snap[:aws_id]} (#{level}): #{snap[:aws_started_at].inspect}, #{snap[:aws_status]} #{snap[:aws_progress]}"
	$logger.debug "Totals: #{hourly} hourly, #{daily} daily, #{weekly} weekly, #{monthly} monthly"

	if eval(level.to_s).to_i > MAX[level]
		$logger.info "Removing expired EBS snapshot #{snap[:aws_id]}"
		ec2.delete_snapshot(snap[:aws_id]) unless options[:dry_run]
	end
end

