require 'uri'
require 'json'
require 'faraday'

require 'builder'
require 'nokogiri'
require 'active_support/all'

ENV['TZ'] = 'Europe/Athens'

PGNAME = 'greek-iptv'
GITURI = 'https://raw.githubusercontent.com/jonian/greek-iptv'

class Provider
  attr_reader :name, :config

  def initialize
    @name   = self.class.name.downcase
    @config = JSON.load(File.read 'tvguide.json')[name]
  end

  def run
    matrix.flat_map do |item|
      parse(fetch item).filter_map do |item|
        process(item) if item
      end
    end
  end

  def matrix
    Array(Date.today.yesterday..Date.today.next_week)
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
  attr_accessor :date, :store

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

    id, name = mapping[chid]

    crow = node.ancestors('tr[bgcolor]').first
    time = crow.first_element_child.text.strip
    desc = crow.css('font').first || node

    data      = context(chid)
    data.date = data.date.tomorrow if data.prev > time.to_i
    data.prev = time.to_i

    {
      channel: {
        id: id,
        name: name
      },
      programme: {
        channel: id,
        start: data.date.strftime("%Y-%m-%d #{time}:00"),
        title: node.text.squish,
        desc: desc.text.squish
      }
    }
  end

  def run
    groups = super.group_by do |item|
      item.dig(:channel, :id)
    end

    groups.values.flat_map do |group|
      group.map.with_index do |item, index|
        node = group[index + 1] || group[0]
        stop = Time.parse node.dig(:programme, :start)
        stop = stop.tomorrow if stop < Time.parse(item.dig(:programme, :start))

        item[:programme][:stop] = stop.to_s
        item
      end
    end
  end

  private

  def context(key)
    self.store      ||= {}
    self.store[key] ||= OpenStruct.new(date: date, prev: -1)

    store[key]
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
