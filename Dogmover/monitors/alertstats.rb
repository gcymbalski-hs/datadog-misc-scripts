require 'json'
require 'uri'
require 'csv'
require 'pry'
require 'spreadsheet'

class Alert
  attr_reader :alert_object
  attr_reader :alert_id

  def initialize(alert_raw_json)
    @alert_object = JSON.parse(alert_raw_json)
    @alert_id = @alert_object['id']
  end

  def name()
    @alert_object['name']
  end

  def message()
    @alert_object['message']
  end

  def tags()
    @alert_object['tags']
  end

  def runbooks()
    URI.extract(message).filter{|u| u =~ /^http/}.collect{|u| u.gsub(/\)/, '')}.uniq.join("\n")
  end

  def alerts()
    /(@slack-[[:word:]]*)/.match(message).to_a.uniq.join("\n")
  end

  def pages()
    /(@pagerduty-[[:word:]]*)/.match(message).to_a.uniq.join("\n")
  end

  def terraform?
    if tags.any?{|tag| tag == 'terraform:true'}
      true
    else
      false
    end
  end

  def product_area
    # note that this is not tracked in a way that we can easily reference for now
    return ''
  end

  def environments()
    envs = tags.select{|tag| tag =~ /env:/}.collect{|x| x.split(':')[1]}
    if message =~ /production/i
      envs << 'production'
    end
    if envs.empty?
      'any (potentially)'
    else
      envs.uniq.join("\n")
    end
  end
  
  def teams()
    tags.select{|tag| tag =~ /team:/}.collect{|x| x.split(':')[1]}.uniq.join("\n")
  end

  def query()
    @alert_object['query']
  end
 
  def resource_name
    /(resource_name:[\w:]*)/.match(query).to_a.collect{|x| x.gsub(/resource_name:/, '')}.uniq.join("\n")
  end

  def summarize()
    [alert_id, '', product_area, name, environments, teams, tags.join("\n"), runbooks, alerts, pages, resource_name, terraform?, message, query]
  end
end

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
