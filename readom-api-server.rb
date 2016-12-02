#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler'
Bundler.require

require 'json'

# === DataMapper Setup === #
DataMapper.setup(:default, ENV['DATABASE_URL'] || 'sqlite::memory:')
DataMapper::Model.raise_on_save_failure = true
DataMapper::Property::String.length(255)
#DataMapper::Logger.new($stdout, :debug)

class Item
  include DataMapper::Resource
  default_scope(:default).update(:order => [:id.asc])

  property :id, Serial
  property :title, String
  property :url, String
  property :by, String
  property :score, Integer
  property :time, DateTime

  property :created_at, DateTime
  property :updated_at, DateTime
  property :deleted_at, ParanoidDateTime
  property :deleted, ParanoidBoolean, :default => false

  before :update, :log_before_update
  after :save, :log_after_save

  def to_json(json_opts=nil)
    {:id => id, :title => title, :url => url, :by => by, :score => score, :time => time.to_time.to_i}.to_json(json_opts)
  end

  def log_before_update
    puts 'Before update id: %s, title: %s' % [id, title]
    true
  end

  def log_after_save
    puts 'After save id: %s, title: %s' % [id, title]
    true
  end

  class <<self
    alias :original_get :get

    def get_or_fetch(id)
      if item = Item.original_get(id) and item.title
        item
      else
        base_uri = 'https://hacker-news.firebaseio.com/v0/item/'
        firebase = Firebase::Client.new(base_uri)
        f_item = firebase.get(id).body

        if f_item['title']
          item = Item.create(:id => f_item['id']) unless item
          item.update :score => f_item['score'], :time => Time.at(f_item['time']), :title => f_item['title'], :url => f_item['url'], :by => f_item['by']

          item
        else
          nil
        end
      end
    end

    alias :get :get_or_fetch
  end
end

DataMapper.finalize
DataMapper.auto_upgrade!
# === end DataMapper === #

class CounterStore
  # store struct
  # - counter_dates: set : 20161201, 20121202
  # - counter_keys: set : pv, uv
  # - counters: hash : date_pv => 110, date_uv => 10
  # - counter_data: hll(pfadd/pfcount) : date_uv
  # UV key:
  # - IP?
  # - Device?
  # - User(Cookie)
  #    Server: get['Cookie_UV'] ? inc counter : (set-cookie[uv] & inc counter)
  #    Client: response['Cookie_UV'] ? 'save to default[uv]' : ""; request["Cookie_UV"] = default[uv]

  def initialize(url=ENV["REDIS_URL"])
    @redis ||= Redis.new(url: url)
  end
end

$info = "Readom API Server"
$time = Time.now.strftime('%FT%T%:z')

class ReadomAPIServer < Sinatra::Base

  enable :sessions

  configure {
    set :server, :puma
  }

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get "/news/v0/:board.:ext" do |board, ext|
    base_uri = 'https://hacker-news.firebaseio.com/v0/'
    firebase = Firebase::Client.new(base_uri)
    list = firebase.get(board).body
    if limit = params['limit'] and max = limit.to_i - 1
      list = list.shuffle[0..max]
    end

    case ext
      when 'json'
        content_type 'application/json'
        list.map{|item_id| Item.get(item_id)}.to_json
      else
        content_type 'text/plain'
        list.join ','
    end
  end

  get '/news/v0/item/:item_id.:ext' do |item_id, ext|
    if item = Item.get(item_id)
      puts 'hit id %d' % [item_id]
    else
      puts 'miss id %d' % [item_id]
      item = {}
    end

    case ext
      when 'json'
        content_type 'application/json'
        item.to_json
      else
        content_type 'text/plain'
        item.to_json
    end
  end

  get '/uvid.:ext' do |ext|
    uvid = request['R-UVID'] || request.cookies['R-UVID'] || request.env['HTTP_R_UVID'] || ''

    case ext
      when 'json'
        content_type 'application/json'
        {:UVID => uvid}.to_json
      else
        content_type 'text/plain'
        'UVID: %s' % uvid
    end
  end

  get '/:ext?' do |ext|
    case ext
      when 'json'
        content_type 'application/json'
        '{"status":"OK", "info":"%s", "time":"%s"}' % [$info, $time]
      else
        content_type 'text/plain'
        'status: OK; info: %s; time: %s' % [$info, $time]
    end
  end
end
