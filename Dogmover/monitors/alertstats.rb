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
    [alert_id, name, environments, teams, runbooks, alerts, pages, resource_name, message, query]
  end
end

alert_defs = Dir.children('.').filter{|c| c =~ /.*\.json$/ && File.stat(c).file? }

alerts = alert_defs.collect{|alert_def| Alert.new(File.read(alert_def))}.sort_by(&:alert_id)

Spreadsheet.client_encoding = 'UTF-8'

book = Spreadsheet::Workbook.new

sheet1 = book.create_worksheet(name: 'Datadog Alert Summary')

sheet1.row(0).concat(['Datadog Alert ID', 'Alert name', 'Environments (from message, tags)', 'Teams (from tags)', 'Runbooks/links', 'Alert channel(s)', 'Paging channel(s)', 'Resource name(s)', 'Alert message (may be parsed)', 'Alert query'])

alerts.each_with_index do |alert, i|
  sheet1.row(i+1).concat alert.summarize
end

book.write('./datadog-alert-summary.xls')
