require 'sinatra'
require 'sinatra/json'
require_relative 'config'
require_relative 'powerbi_service'
require_relative 'chat_engine'

set :public_folder, File.join(File.dirname(__FILE__), 'static')
set :static, true
set :views, File.join(File.dirname(__FILE__), 'templates')

# Sinatra doesn't have a direct equivalent to lifespan, but we can use before
configure do
  Settings.logger.info "Power BI RLS Chatbot starting …"
  schema_path = File.join(File.dirname(__FILE__), "sample_report", "schema.json")
  rls_path = File.join(File.dirname(__FILE__), "rls_config.json")
  if !File.exist?(schema_path) || !File.exist?(rls_path)
    Settings.logger.warn(
      "┌────────────────────────────────────────────────────┐\n" \
      "│  First run detected!  Run:  ruby setup.rb          │\n" \
      "│  to auto-discover schema and RLS configuration.    │\n" \
      "└────────────────────────────────────────────────────┘"
    )
  end
end

get '/' do
  erb :index, locals: { demo_users: Settings.demo_users }
end

post '/api/embed-token' do
  payload = JSON.parse(request.body.read)
  rls_username = payload['rls_username']
  
  begin
    data = PowerBIService.generate_embed_token(rls_username)
    json data
  rescue => e
    status 500
    json({ error: e.message })
  end
end

post '/api/chat' do
  payload = JSON.parse(request.body.read)
  message = payload['message']
  rls_username = payload['rls_username']
  history = payload['history'] || []
  
  begin
    result = ChatEngine.chat(message, rls_username, history)
    json result
  rescue => e
    status 500
    json({ error: e.message })
  end
end

get '/health' do
  json({ status: 'ok' })
end
