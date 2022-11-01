require 'json'
require 'uri'
require 'pry'
require 'rubyXL'
require 'rubyXL/convenience_methods'
require 'datadog_api_client'

require './lib/alerts.rb'

DatadogAPIClient.configure do |config|
  config.debugging = true if ENV['DEBUG'] == 'true'
end

local_alert_defs = Dir.children('.').filter{|c| c =~ /.*\.json$/ && File.stat(c).file? }
local_alerts = local_alert_defs.collect{|alert_def| Alert.new(File.read(alert_def))}.sort_by(&:alert_id)

# completely ignore the default 'ntp' alert that datadog generated
local_alerts = local_alerts.select{|alert| alert.alert_id != 3618226}

# exported from the google sheet that EMs have been putting new mappings into
exported_workbook = RubyXL::Parser.parse("./current-alert-status-10312022.xlsx")
workbook_alerts = local_alerts.collect{|alert| get_alert_from_workbook(alert.alert_id, exported_workbook)}.compact

# find alerts that may have changed since our original export and the workbook today
alerts_with_changes       = get_all_alert_diffs(local_alerts, workbook_alerts).compact

# find alerts that may be missing entirely from the workbook that existed during the original export
missing_alerts            = get_missing_alerts(local_alerts, workbook_alerts)

# find alerts that we will NOT need to manage since they are handled with terraform
terraform_alerts          = local_alerts.collect{|alert| alert.alert_id if alert.terraform?}.compact

# find alerts with a nil value for 'new owner' - probably already owned
alerts_with_no_new_owner = workbook_alerts.select{|alert| alert.new_team.nil?}
completely_unowned       = alerts_with_no_new_owner.select{|alert| ! alert.tags.any?{|t| t =~ /team/}}.compact
# complete list of team tags from the 'alerts with no "new" owner' set:
# alerts_with_no_new_owner.collect{|x| x.tags.select{|t| t =~ /team/}}.flatten.uniq
# => ["team:platform", "team:iam", "team:data", "team:notifications", "team:devx", "team:cloud-engineering", "team:messaging"]
#   these look safe to me
puts "Size of completely unowned alerts set: #{completely_unowned.count}"

# set of alerts we've been asked to remove entirely
alerts_to_remove = workbook_alerts.select{|x| x.to_delete == true}
puts "Alerts requested to be deleted: #{alerts_to_remove.collect{|x| x.alert_id}.join(', ')}"

# complete set of new owners
new_alert_owners = workbook_alerts.collect{|x| x.new_team.downcase if x.new_team}.compact.uniq.count

# alerts that are still set to a 'shared' owner
shared_alerts    = workbook_alerts.select do |x|
  if x.raw_new_owner
    x.raw_new_owner.downcase =~ /shared/ || x.raw_new_owner.downcase =~ /service owner/
  else
    nil
  end
end

puts "Size of 'shared' unowned alerts set: #{shared_alerts.count}"
puts "'Shared' alert IDs to be pared down: #{shared_alerts.collect{|x| x.alert_id}.join(', ')}"

puts "Raw owner names that still need to be mapped to teams/squads:"
puts workbook_alerts.collect{|x| x.raw_new_owner.downcase if ( x.new_team.nil? && x.raw_new_owner ) }.compact.uniq.join("\n")

binding.pry

exit

monitor_client = DatadogAPIClient::V1::MonitorsAPI.new
