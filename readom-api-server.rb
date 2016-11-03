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

  def to_json
    {:id => id, :title => title, :url => url, :by => by, :score => score, :time => time.to_time.to_i}.to_json
  end

  def log_before_update
    puts 'Before update id: %s, title: %s' % [id, title]
    true
  end

  def log_after_save
    puts 'After save id: %s, title: %s' % [id, title]
    true
  end
end

DataMapper.finalize
DataMapper.auto_upgrade!
# === end DataMapper === #

class ReadomAPIServer < Sinatra::Base

  enable :sessions

  configure {
    set :server, :puma
  }

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get '/:ext?' do |ext|
    case ext
      when 'json'
        content_type 'application/json'
        '{"status":"OK", "info":"Readom API Server"}'
      else
        content_type 'text/plain'
        'Readom API Server'
    end
  end

  get "/news/v0/:board.:ext" do |board, ext|
    base_uri = 'https://hacker-news.firebaseio.com/v0/'
    firebase = Firebase::Client.new(base_uri)
    list = firebase.get(board).body

    case ext
      when 'json'
        content_type 'application/json'
        list.to_json
      when 'sample'
        content_type 'application/json'
        [list.sample].to_json
      else
        content_type 'text/plain'
        list.join ','
    end
  end

  get '/news/v0/item/:item_id.:ext' do |item_id, ext|
    if item = Item.first(:id => item_id) and item.title
    else
      base_uri = 'https://hacker-news.firebaseio.com/v0/item/'
      firebase = Firebase::Client.new(base_uri)
      f_item = firebase.get(item_id).body

      item = Item.first_or_create :id => f_item['id']
      item.update :score => f_item['score'], :time => Time.at(f_item['time']), :title => f_item['title'], :url => f_item['url'], :by => f_item['by']
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
end
