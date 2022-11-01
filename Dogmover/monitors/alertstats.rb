require 'json'
require 'uri'
require 'pry'
require 'spreadsheet'

require './lib/alerts.rb'

alert_defs = Dir.children('.').filter{|c| c =~ /.*\.json$/ && File.stat(c).file? }

alerts = alert_defs.collect{|alert_def| Alert.new(File.read(alert_def))}.sort_by(&:alert_id)

binding.pry if ENV['DEBUG'] == 'true'

Spreadsheet.client_encoding = 'UTF-8'

book = Spreadsheet::Workbook.new

categories = %w{Employer University Student Platform Identity Cloud-Engineering DevX Messaging Stragglers}

total = 0

categories.each do |category|
  sheet = book.create_worksheet(name: category)

  match_criteria = case category.downcase
                   when 'platform'
                     %w{platform iam data notifications}
                   when 'stragglers'
                     ['']
                   else
                     [category.downcase]
                   end

  sheet.row(0).concat(['Datadog Alert ID', 'New owner', 'Product Area', 'Alert name', 'Environments (from message, tags)', 'Teams (from tags)', 'Raw tags', 'Runbooks/links', 'Alert channel(s)', 'Paging channel(s)', 'Resource name(s)', 'Terraformed?', 'Alert message (may be parsed)', 'Alert query'])

  category_alerts = alerts.select do |alert|
    match_criteria.any? do |c|
      alert.teams.match?(/#{c}/)
    end
  end

  # pigeonhole alerts to one area
  alerts = alerts - category_alerts

  category_alerts.each_with_index do |alert, i|
    sheet.row(i+1).concat alert.summarize
  end
  puts "Processed #{category_alerts.count} alerts in #{category}"
  total = total + category_alerts.count
end

puts "Processed #{total} alerts"
book.write('./datadog-alert-summary.xls')
