require 'sinatra/base'
require 'pg'
require 'dotenv'
require 'json'
require 'date'

Dotenv.load

class DompetHarian < Sinatra::Base
  def self.setup_database
    user = ENV['DB_USER'] || ENV['USER'] || 'yaakhi'
    puts "Initializing database for user: #{user}..."
    
    # 1. Connect to default postgres DB to ensure dompet_harian database exists
    begin
      conn = PG.connect(dbname: 'postgres', user: user)
      db_exists = conn.exec("SELECT 1 FROM pg_database WHERE datname = 'dompet_harian'").any?
      unless db_exists
        conn.exec("CREATE DATABASE dompet_harian")
        puts "Database 'dompet_harian' created successfully."
      end
    rescue => e
      puts "Notice during DB check/creation: #{e.message}"
    ensure
      conn.close if conn
    end

    # 2. Connect to dompet_harian database and create schema
    begin
      conn = PG.connect(dbname: 'dompet_harian', user: user)
      conn.exec <<-SQL
        CREATE TABLE IF NOT EXISTS expenses (
          id SERIAL PRIMARY KEY,
          title VARCHAR(100) NOT NULL,
          amount NUMERIC(15, 2) NOT NULL,
          category VARCHAR(50) NOT NULL,
          date DATE NOT NULL,
          notes TEXT,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      SQL
      puts "Table 'expenses' checked/created successfully."
    rescue => e
      puts "Database initialization failed: #{e.message}"
      raise e
    ensure
      conn.close if conn
    end
  end

  # Configure Sinatra
  configure do
    set :public_folder, File.dirname(__FILE__) + '/public'
    set :views, File.dirname(__FILE__) + '/views'
    enable :sessions
    set :session_secret, 'supersecretkey_dompetharian'

    # Auto-initialize database on startup
    setup_database
  end

  # DB Connection helper for request lifetime
  helpers do
    def db
      @db ||= PG.connect(dbname: 'dompet_harian', user: ENV['DB_USER'] || ENV['USER'] || 'yaakhi')
    end

    def format_idr(number)
      # Format: Rp 150.000
      parts = number.to_f.round.to_s.split('.')
      integer_part = parts[0].gsub(/(\d)(?=(\d\d\d)+(?!\d))/, '\\1.')
      "Rp #{integer_part}"
    end

    def format_date(date_str)
      # Format YYYY-MM-DD to readable Indonesian format: e.g. 24 Jun 2026
      date = Date.parse(date_str)
      months = %w[Jan Feb Mar Apr Mei Jun Jul Agu Sep Okt Nov Des]
      "#{date.day} #{months[date.month - 1]} #{date.year}"
    end

    def category_icon(category)
      case category
      when 'Makanan & Minuman' then 'utensils'
      when 'Transportasi' then 'car'
      when 'Tagihan & Utilitas' then 'receipt'
      when 'Hiburan & Rekreasi' then 'gamepad-2'
      when 'Belanja' then 'shopping-bag'
      when 'Kesehatan' then 'heart-pulse'
      else 'credit-card'
      end
    end

    def category_color_class(category)
      case category
      when 'Makanan & Minuman' then 'cat-food'
      when 'Transportasi' then 'cat-transport'
      when 'Tagihan & Utilitas' then 'cat-bills'
      when 'Hiburan & Rekreasi' then 'cat-entertainment'
      when 'Belanja' then 'cat-shopping'
      when 'Kesehatan' then 'cat-health'
      else 'cat-others'
      end
    end
  end

  after do
    @db.close if @db
  end

  # Predefined categories for UI forms
  CATEGORIES = [
    'Makanan & Minuman',
    'Transportasi',
    'Tagihan & Utilitas',
    'Hiburan & Rekreasi',
    'Belanja',
    'Kesehatan',
    'Lainnya'
  ].freeze

  # --- ROUTES ---

  # 1. Dashboard View
  get '/' do
    # Fetch statistics
    today = Date.today.to_s
    first_of_month = Date.new(Date.today.year, Date.today.month, 1).to_s
    
    # Total Today
    res_today = db.exec_params("SELECT SUM(amount) FROM expenses WHERE date = $1", [today])
    @total_today = res_today[0]['sum'] ? res_today[0]['sum'].to_f : 0.0

    # Total This Month
    res_month = db.exec_params("SELECT SUM(amount) FROM expenses WHERE date >= $1 AND date <= CURRENT_DATE", [first_of_month])
    @total_month = res_month[0]['sum'] ? res_month[0]['sum'].to_f : 0.0

    # Average Daily This Month
    day_count = Date.today.day
    @avg_daily = day_count > 0 ? (@total_month / day_count) : 0.0

    # Recent 5 expenses
    @recent_expenses = db.exec("SELECT * FROM expenses ORDER BY date DESC, id DESC LIMIT 5").to_a

    # Category breakdown for charts
    @category_stats = db.exec <<-SQL
      SELECT category, SUM(amount) as total 
      FROM expenses 
      WHERE date >= '#{first_of_month}' 
      GROUP BY category 
      ORDER BY total DESC
    SQL
    @category_stats = @category_stats.to_a

    @categories = CATEGORIES
    erb :dashboard
  end

  # 2. History & Filters View
  get '/expenses' do
    # Read filter query params
    @search_query = params[:search]
    @category_filter = params[:category]
    @start_date = params[:start_date]
    @end_date = params[:end_date]

    sql_parts = ["SELECT * FROM expenses WHERE 1=1"]
    params_list = []
    param_idx = 1

    if @search_query && !@search_query.strip.empty?
      sql_parts << "AND title ILIKE $#{param_idx}"
      params_list << "%#{@search_query}%"
      param_idx += 1
    end

    if @category_filter && !@category_filter.empty?
      sql_parts << "AND category = $#{param_idx}"
      params_list << @category_filter
      param_idx += 1
    end

    if @start_date && !@start_date.empty?
      sql_parts << "AND date >= $#{param_idx}"
      params_list << @start_date
      param_idx += 1
    end

    if @end_date && !@end_date.empty?
      sql_parts << "AND date <= $#{param_idx}"
      params_list << @end_date
      param_idx += 1
    end

    sql_parts << "ORDER BY date DESC, id DESC"
    full_sql = sql_parts.join(" ")

    @expenses = db.exec_params(full_sql, params_list).to_a
    @categories = CATEGORIES
    
    erb :expenses
  end

  # 3. Add Expense (Supports normal form POST and AJAX)
  post '/expenses' do
    title = params[:title]
    amount = params[:amount].to_f
    category = params[:category]
    date = params[:date]
    notes = params[:notes]

    # Validate inputs
    if title.nil? || title.strip.empty? || amount <= 0 || category.nil? || date.nil? || date.empty?
      status 400
      if request.xhr?
        content_type :json
        return { success: false, error: 'Silakan isi semua field dengan benar!' }.to_json
      else
        session[:error] = 'Silakan isi semua field dengan benar!'
        redirect back
      end
    end

    # Insert into database
    begin
      db.exec_params(
        "INSERT INTO expenses (title, amount, category, date, notes) VALUES ($1, $2, $3, $4, $5)",
        [title, amount, category, date, notes]
      )

      if request.xhr?
        content_type :json
        status 200
        { success: true, message: 'Catatan pengeluaran berhasil disimpan!' }.to_json
      else
        session[:success] = 'Catatan pengeluaran berhasil disimpan!'
        redirect '/'
      end
    rescue => e
      status 500
      if request.xhr?
        content_type :json
        { success: false, error: "Gagal menyimpan ke database: #{e.message}" }.to_json
      else
        session[:error] = "Gagal menyimpan ke database: #{e.message}"
        redirect back
      end
    end
  end

  # 4. Delete Expense
  post '/expenses/:id/delete' do
    id = params[:id].to_i
    
    begin
      result = db.exec_params("DELETE FROM expenses WHERE id = $1", [id])
      
      if request.xhr?
        content_type :json
        status 200
        { success: true, message: 'Catatan berhasil dihapus!' }.to_json
      else
        session[:success] = 'Catatan berhasil dihapus!'
        redirect back
      end
    rescue => e
      status 500
      if request.xhr?
        content_type :json
        { success: false, error: "Gagal menghapus catatan: #{e.message}" }.to_json
      else
        session[:error] = "Gagal menghapus catatan: #{e.message}"
        redirect back
      end
    end
  end

  # 5. Reports & Charts View (and data API)
  get '/reports' do
    # Category totals (This month)
    first_of_month = Date.new(Date.today.year, Date.today.month, 1).to_s
    
    # 1. Doughnut chart data (Category totals)
    category_data = db.exec <<-SQL
      SELECT category, SUM(amount) as total 
      FROM expenses 
      WHERE date >= '#{first_of_month}' 
      GROUP BY category
    SQL
    @category_chart = category_data.map { |row| { category: row['category'], total: row['total'].to_f } }

    # 2. Line chart data (Daily spending trend last 30 days)
    thirty_days_ago = (Date.today - 30).to_s
    daily_data = db.exec_params <<-SQL, [thirty_days_ago]
      SELECT date, SUM(amount) as total 
      FROM expenses 
      WHERE date >= $1 
      GROUP BY date 
      ORDER BY date ASC
    SQL
    
    # Build complete list of last 30 days to fill in gaps with 0
    date_map = {}
    daily_data.each { |row| date_map[row['date']] = row['total'].to_f }
    
    @daily_trend = []
    (30).downto(0) do |i|
      d = (Date.today - i).to_s
      @daily_trend << { date: d, formatted_date: Date.parse(d).strftime('%d %b'), total: date_map[d] || 0.0 }
    end

    if request.xhr?
      content_type :json
      { categories: @category_chart, daily: @daily_trend }.to_json
    else
      erb :reports
    end
  end
end
