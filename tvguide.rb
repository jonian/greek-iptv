require 'uri'
require 'json'
require 'faraday'

require 'builder'
require 'nokogiri'
require 'active_support/all'

PGNAME = 'greek-iptv'
GITURI = 'https://raw.githubusercontent.com/jonian/greek-iptv'

class Provider
  attr_reader :name, :config

  def initialize
    @name   = self.class.name.downcase
    @config = JSON.load(File.read 'tvguide.json')[name]
  end

  def run
    items = matrix.flat_map do |item|
      parse(fetch item)
    end

    items.compact.filter_map do |item|
      process(item)
    end
  end

  def matrix
    Array(Date.today..Date.today.next_week)
  end

  def fetch
    raise NotImplementedError
  end

  def parse(data)
    Array(data)
  end

  def process(item)
    Hash(item)
  end

  private

  def connection
    Faraday.new(config['url'], headers: config['headers'], ssl: { verify: false })
  end

  def request(method, path = nil, body: nil, data: nil, **kwargs)
    resp = connection.send(method, path, **kwargs) do |req|
      req.body = JSON.generate(data) if body
      req.body = URI.encode_www_form(data) if data
    end

    resp.body
  end

  def mapping
    config.fetch('mapping', {})
  end
end

class Digea < Provider
  def fetch(date)
    request(:post, data: {
      action: 'get_events',
      date: date
    })
  end

  def parse(data)
    JSON.load(data)
  end

  def process(item)
    item = OpenStruct.new(**item)
    return unless mapping.key?(item.channel_id)

    id, name = mapping[item.channel_id]

    {
      channel: {
        id: id,
        name: name
      },
      programme: {
        channel: id,
        start: item.actual_time,
        stop: item.end_time,
        title: item.title_gre,
        desc: item.long_synopsis_gre
      }
    }
  end
end

class Ert < Provider
  attr_accessor :date

  def fetch(date)
    self.date = date

    request(:post, data: {
      frmDates: date.strftime('%j'),
      frmChannels: '',
      frmSearch: '',
      x: '14',
      y: '6'
    })
  end

  def parse(data)
    Nokogiri::HTML(data).css('a.black')
  end

  def process(node)
    chid = node.attr(:href).match(/chid=(\d+)/)[1]
    return unless mapping.key?(chid)

    crow = node.ancestors('tr[bgcolor]').first
    time = crow.first_element_child.text.strip
    desc = crow.css('font').first || node

    nrow = next_row(crow)
    stop = nrow.first_element_child.text.strip

    id, name = mapping[chid]

    {
      channel: {
        id: id,
        name: name
      },
      programme: {
        channel: id,
        start: date.strftime("%Y-%m-%d #{time}:00"),
        stop: date.strftime("%Y-%m-%d #{stop}:00"),
        title: node.text.squish,
        desc: desc.text.squish
      }
    }
  end

  private

  def next_row(node)
    row = node.next_element || node.parent.first_element_child
    row.css('a.black').any? ? row : next_row(row)
  end
end

class Parser
  attr_reader :ids

  def initialize
    @ids = JSON.load(File.read 'channels.json').map do |item|
      item['name']
    end
  end

  def run
    xml = Builder::XmlMarkup.new(indent: 2)
    xml.instruct! :xml, version: '1.0'
    xml.declare! :DOCTYPE, :tv, :SYSTEM, 'xmltv.dtd'

    xml.tv('generator-info-name' => PGNAME, 'generator-info-url' => GITURI) do
      channels.each do |channel|
        xml.channel **channel.slice(:id) do
          xml.tag! 'display-name', channel[:name], lang: 'el'
        end
      end

      programmes.each do |programme|
        programme[:start] = time programme[:start]
        programme[:stop]  = time programme[:stop]

        xml.programme **programme.slice(:start, :stop, :channel) do
          xml.title programme[:title], lang: 'el'
          xml.desc programme[:desc]
        end
      end
    end

    File.write('tvguide.xml', xml.target!)
  end

  private

  def tvdata
    @tvdata ||= Provider.descendants.flat_map do |provider|
      provider.new.run
    end
  end

  def channels
    @channels ||= tvdata
      .map    { |item| item[:channel] }
      .uniq   { |item| item[:id] }
      .select { |item| ids.include? item[:id] }
  end

  def programmes
    @programmes ||= tvdata
      .map    { |item| item[:programme] }
      .select { |item| ids.include? item[:channel] }
      .map    { |item| item.transform_values!(&:strip) }
  end

  def time(string)
    Time.parse(string).strftime('%Y%m%d%H%M%S %z')
  end
end

parser = Parser.new
parser.run
