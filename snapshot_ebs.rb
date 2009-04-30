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

p distance_in_minutes
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
MAX = { :hourly => 3, :daily => 6, :weekly => 3, :monthly => 6 }
MAX_TOTAL = MAX.values.inject(0) {|x, sum| sum + x}
monthly = weekly = daily = hourly = 0
last_level = first_time = nil
# Iterate through the snapshots NEWEST FIRST!
ec2.describe_snapshots.sort {|a, b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snap|
	# Make sure we're dealing with this volume
	next unless volumes.map {|vol| vol[:aws_id] }.include?(snap[:aws_volume_id])

	# Check dates and determine what "level" we're looking at
	first_time ||= snap[:aws_started_at]
	case level = difference_in_time(first_time, snap[:aws_started_at])
		when :hourly
			hourly += 1
		when :daily
			daily += 1
		when :weekly
			weekly += 1
		when :monthly
			monthly += 1
	end

	first_time = snap[:aws_started_at] if last_level != level
	last_level = level

	$logger.info "Snapshot #{snap[:aws_id]} (#{level}): #{snap[:aws_started_at].inspect}, #{snap[:aws_status]} #{snap[:aws_progress]}"
	$logger.debug "Totals: #{hourly} hourly, #{daily} daily, #{weekly} weekly, #{monthly} monthly"

	if eval(level.to_s).to_i > MAX[level] #and (hourly + daily + weekly + monthly) > MAX_TOTAL
		$logger.info "Removing expired EBS snapshot #{snap[:aws_id]}"
		ec2.delete_snapshot(snap[:aws_id]) unless options[:dry_run]
	end
end

