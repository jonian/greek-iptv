require 'uri'
require 'json'
require 'faraday'

require 'builder'
require 'nokogiri'
require 'unaccent'

require 'active_support/all'

ENV['TZ'] = 'Europe/Athens'

module TvGuide
  PGNAME = 'greek-iptv'
  GITURI = 'https://raw.githubusercontent.com/jonian/greek-iptv'

  class Provider
    attr_reader :name, :config

    def initialize
      @name   = self.class.name.demodulize.downcase
      @config = JSON.load(File.read 'tvguide.json')[name]

      raise "Config not found for #{name}!" if config.nil?
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
        req.body = JSON.generate(body) if body
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
      request(:post, data: { action: 'get_events', date: date })
    end

    def parse(data)
      JSON.load(data)
    end

    def process(item)
      chid = item.fetch('channel_id', '0')
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: item['actual_time'],
          stop: item['end_time'],
          title: item['title_gre'],
          desc: item['long_synopsis_gre']
        }
      }
    end
  end

  class Ertflix < Provider
    def fetch(date)
      data = request(:post, 'v1/EpgTile/FilterProgramTiles', body: {
        platformCodename: 'www',
        from: date.rfc3339,
        to: date.tomorrow.rfc3339,
        orChannelCodenames: mapping.keys
      })

      request(:post, 'v2/Tile/GetTiles', body: {
        platformCodename: 'www',
        requestedTiles: JSON.load(data)
          .fetch('Programs', {})
          .values.flatten
          .map { |item| { id: item['Id'] } }
      })
    end

    def parse(data)
      JSON.load(data).fetch('Tiles', [])
    end

    def process(item)
      chid = item.dig('TileChannel', 'Codename')
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: item['Start'],
          stop: item['Stop'],
          title: item['Title'],
          desc: item['Description'] || item['Title']
        }
      }
    end
  end

  class Vouli < Provider
    attr_reader :date, :nodes, :prev

    def fetch(date)
      @prev = -1
      @date = date

      request(:get, id: 8, pdate: date.strftime('%d/%m/%Y'))
    end

    def parse(data)
      @nodes = Nokogiri::HTML(data).xpath('//tr[@bgcolor][.//a[@class="black"]]')
    end

    def process(node)
      id, name = ['ert.vouli.gr', 'VOULI']

      index = nodes.index(node)
      nitem = nodes[index + 1] || nodes[0]

      title = node.css('a.black').first
      desc  = node.css('font').first || title
      start = node.first_element_child.text.strip
      stop  = nitem.first_element_child.text.strip

      @date = date.tomorrow if prev > start.to_i
      @prev = start.to_i

      sdate = start.to_i > stop.to_i ? date.tomorrow : date
      start = date.strftime("%Y-%m-%d #{start}:00")
      stop  = sdate.strftime("%Y-%m-%d #{stop}:00")

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: start,
          stop: stop,
          title: title.text.squish,
          desc: desc.text.squish
        }
      }
    end
  end

  class Builder
    attr_reader :ids

    def initialize
      @ids = JSON.load(File.read 'channels.json').map do |item|
        item['name']
      end
    end

    def run
      xml = ::Builder::XmlMarkup.new(indent: 2)
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

  class << self
    def run
      builder = Builder.new
      builder.run
    end
  end
end
