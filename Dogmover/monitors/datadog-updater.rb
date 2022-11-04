require 'json'
require 'uri'
require 'pry'

# needed for parsing our input spreadsheet
require 'rubyXL'
require 'rubyXL/convenience_methods'

# significantly more straightforward way of writing new spreadsheets
require 'spreadsheet'

require 'datadog_api_client'

require './lib/alerts.rb'

DEBUG = ENV['DEBUG'] == 'true'
PRY   = ENV['PRY'] == 'true'
START_TIME = Time.now.strftime("%Y-%m-%d-%H%M%S")

REALLY_UPDATE_DATADOG = ENV['DRY_RUN'] == 'false'

DatadogAPIClient.configure do |config|
  config.debugging = true if ENV['DEBUG'] == 'true'
end

local_alert_defs = Dir.children('.').filter{|c| c =~ /.*\.json$/ && File.stat(c).file? }
local_alerts = local_alert_defs.collect do |alert_def|
  Alert.new(File.read(alert_def))
end.sort_by(&:alert_id)

# completely ignore the default 'ntp' alert that datadog generated
local_alerts = local_alerts.select{|alert| alert.alert_id != 3618226}

# exported from the google sheet that EMs have been putting new mappings into
exported_workbook = RubyXL::Parser.parse("./current-alert-status-10312022.xlsx")
workbook_alerts = local_alerts.collect do |alert|
  get_alert_from_workbook(alert.alert_id, exported_workbook, alert)
end.compact

puts "Amount of alerts found in workbook: #{workbook_alerts.count}"

inconsistent_alerts = []
workbook_inconsistent = local_alerts.any? do |local_alert|
  workbook_alert = get_alert(local_alert.alert_id, workbook_alerts)
  if ! workbook_alert
    # no matching alert- that's fine
    false
  elsif workbook_alert.message == local_alert.message && \
      workbook_alert.query == local_alert.query && \
      workbook_alert.name == local_alert.name && \
      workbook_alert.tags == local_alert.tags
    false
  else
    puts "#{local_alert.alert_id}: inconsistent query/name/tags between curent alerts and worksheet"
    inconsistent_alerts << local_alert.alert_id
    workbook_alert.update_message_from(local_alert)
    workbook_alert.update_query_from(local_alert)
    workbook_alert.update_tags_from(local_alert)
    binding.pry if PRY
    true
  end
end

puts "Reprocessing alerts with data from latest workbook..."
workbook_alerts.each{|x| x.reprocess_alert}

binding.pry if PRY

puts ''
puts 'SANITY CHECKS'
puts 'Complete set of new alert owners: '
new_alert_owners = workbook_alerts.collect{|x| "#{[x.new_team,x.new_squad].join(' > ')}"}.compact.uniq.sort
puts new_alert_owners.join("\n")
puts ''

puts "Raw owner names that still need to be mapped to teams/squads:"
owners_that_need_remapping = workbook_alerts.collect do |x|
  if x.new_team.nil? && x.raw_new_owner
    x.raw_new_owner.downcase
  end
end.compact.uniq

puts owners_that_need_remapping.join("\n")

# find alerts that may be missing entirely from the workbook that existed during the original export
missing_alerts            = get_missing_alerts(local_alerts, workbook_alerts)

# find alerts with a nil value for 'new owner' - probably already owned
alerts_with_no_new_owner = workbook_alerts.select{|alert| alert.new_team.nil?}
completely_unowned       = alerts_with_no_new_owner.select{|alert| ! alert.tags.any?{|t| t =~ /team/}}.compact

# complete list of team tags from the 'alerts with no "new" owner' set:
# alerts_with_no_new_owner.collect{|x| x.tags.select{|t| t =~ /team/}}.flatten.uniq
# ["team:platform", "team:iam", "team:data", "team:notifications", "team:devx", "team:cloud-engineering", "team:messaging"]
#   these look safe to me
completely_unowned_log = "./completely_unowned.log"
puts "Amount of completely unowned alerts (including no team tag) set: #{completely_unowned.count}"
puts "Writing set of unowned alerts to #{completely_unowned_log}"
File.write(completely_unowned_log, completely_unowned.collect{|x| "#{x.alert_id} - #{x.name}"}.join("\n"))

# set of alerts we've been asked to remove entirely
alerts_to_remove = workbook_alerts.select{|x| x.to_delete == true}
alerts_to_remove_ids = alerts_to_remove.collect{|x| x.alert_id}
delete_request_log = './to_delete.log'
puts "Amount of alerts requested to be deleted: #{alerts_to_remove_ids.count}"
puts "Writing delete-able alert set to #{delete_request_log}"
File.write(delete_request_log, alerts_to_remove.collect{|x| "#{x.alert_id} - #{x.name}"}.join("\n"))

# alerts that are still set to a 'shared' owner
shared_alerts    = workbook_alerts.select do |x|
  if x.new_team
    x.new_team == 'shared-monolith' || x.new_team == 'service-owner'
  else
    nil
  end
end
shared_ids = shared_alerts.collect{|x| x.alert_id}
shared_alert_log = "./shared_alerts.log"
puts "Size of 'shared' unowned alerts set: #{shared_ids.count}"
puts "Writing shared unowned alert set to #{shared_alert_log}"
File.write(shared_alert_log, shared_alerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts 'END OF SANITY CHECKS'
puts ''

puts "Excluding alerts that do not have diffs from the desired and actual state..."
workbook_alerts.reject!{|x| ! alert_diff(x.alert_id, local_alerts, workbook_alerts)}

puts "Initial amount of alerts that will need to be updated: #{workbook_alerts.count}"

# terraform-managed alerts that will need updates
terraform_fixup_log = "./to_fix_in_terraform.log"
puts "Writing terraform-managed alerts that will need updates to #{terraform_fixup_log}"
terraform_alerts = workbook_alerts.select{|x| x.terraform?}
File.write(terraform_fixup_log, terraform_alerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts ''

# alerts with multiple slack channel pairings with potential conditionals that are both not terraformed 
# and also do not reference the deprecated UK alerts channel
# (same should be done for paging channels)
non_terraform_non_uk_multialerts = workbook_alerts.select do |x|
    x.alerts.reject{|x| x == '@slack-incidents-uk' }.count > 1
  end.select do |x|
    x.alerts_in_conditionals?
  end.select do |x|
    ! x.terraform?
  end

multialertcount = non_terraform_non_uk_multialerts.count
multialert_ids  = non_terraform_non_uk_multialerts.collect{|x| x.alert_id}

puts "Size of set of alerts that target multiple slack channels (excluding UK or terraform-managed): #{multialertcount}"
multi_fixup_log     = "./multi_alert_channels_to_fix_manually.txt"
puts "Writing alerts that need manual adjustments to #{multi_fixup_log}"
File.write(multi_fixup_log, non_terraform_non_uk_multialerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts ''

puts "Finalizing the set of alerts to update..."

puts "Excluding alerts that can not be programmatically updated (from the multi-alert set above)..."
workbook_alerts.reject!{|x| multialert_ids.include?(x.alert_id)}

puts "Excluding terraform alerts..."
workbook_alerts.reject!{|x| x.terraform? }

puts "Excluding 'shared' alerts that need more help..."
workbook_alerts.reject!{|x| shared_ids.include?(x.alert_id)}

puts "Excluding set of alerts that people wanted to delete..."
workbook_alerts.reject!{|x| alerts_to_remove_ids.include?(x.alert_id)}

puts "Excluding alerts meant for deletion..."
workbook_alerts.reject!{|x| x.to_delete == true }

puts "Final amount of alerts to update: #{workbook_alerts.count}"

def report_diff(spreadsheet, workbook_name, new_alert_configs, old_alert_configs)
  output_sheet = spreadsheet.create_worksheet(name: 'Terraform Alerts to Fix')
  new_message_col_name = if workbook_name =~ /terraform|multi/
                           'Proposed New Message (SUGGESTION ONLY)'
                         else
                           'New Message'
                         end
  output_sheet.row(0).concat(['Datadog Alert ID', 'New Team', 'New Squad', 'Alert Name', 'New Alert Slack Channel', 'New Pagerduty Service', 'Update Slack?', 'Update Pagerduty?', 'Original Message', new_message_col_name])
  new_alert_configs.each_with_index do |new_alert, i|
    alert_id          = new_alert.alert_id
    old_alert         = get_alert(alert_id, old_alert_configs)
    new_team          = new_alert.new_team
    new_squad         = new_alert.new_squad
    alert_name        = new_alert.name
    new_slack_channel = new_alert.new_slack_channel
    new_pagerduty_service = new_alert.new_pagerduty_service
    # as of nov. 1
    update_slack      = true
    update_pagerduty  = false
    original_message  = old_alert.message
    new_message       = new_alert.message
    output_sheet.row(i).concat [alert_id, new_team, new_squad, alert_name, new_slack_channel, new_pagerduty_service, update_slack, update_pagerduty, original_message, new_message]
  end
end


Spreadsheet.client_encoding = 'UTF-8'
report_workbook = Spreadsheet::Workbook.new
report_diff(report_workbook, 'Alerts that will be Automatically Changed', workbook_alerts, local_alerts)
report_diff(report_workbook, 'Terraform Alerts to Fix',  terraform_alerts, local_alerts)
report_diff(report_workbook, 'Multi-Channel Alerts to Fix',  non_terraform_non_uk_multialerts, local_alerts)
report_diff(report_workbook, 'Alerts to Remove',  alerts_to_remove, local_alerts)
report_diff(report_workbook, 'Shared Alerts - No Updates', shared_alerts, local_alerts)
report_diff(report_workbook, 'Completely Unowned Alerts - No Updates', completely_unowned, local_alerts)
report_workbook.write("./report-update-summary-#{START_TIME}.xls")

binding.pry if PRY

exit

monitor_client = DatadogAPIClient::V1::MonitorsAPI.new
