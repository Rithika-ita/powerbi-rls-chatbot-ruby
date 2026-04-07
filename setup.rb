require 'json'
require 'rest-client'
require 'dotenv/load'
require 'optparse'
require 'pathname'

# Colors
GREEN = "\e[92m"
YELLOW = "\e[93m"
RED = "\e[91m"
BLUE = "\e[94m"
BOLD = "\e[1m"
END_COLOR = "\e[0m"

def ok(msg); puts "  #{GREEN}✓#{END_COLOR} #{msg}"; end
def warn(msg); puts "  #{YELLOW}⚠#{END_COLOR} #{msg}"; end
def fail(msg); puts "  #{RED}✗#{END_COLOR} #{msg}"; end
def info(msg); puts "  #{BLUE}ℹ#{END_COLOR} #{msg}"; end
def step(n, total, msg); puts "\n#{BOLD}Step #{n}/#{total}: #{msg}#{END_COLOR}"; end

def ask(prompt, default = "")
  print "  #{prompt}#{default.empty? ? "" : " [#{default}]"}: "
  input = gets.strip
  input.empty? ? default : input
end

def ask_choice(prompt, options, default = 1)
  puts "\n  #{prompt}"
  options.each_with_index do |opt, i|
    marker = (i + 1) == default ? " #{BLUE}← suggested#{END_COLOR}" : ""
    puts "    [#{i + 1}] #{opt}#{marker}"
  end
  print "  Choice [#{default}]: "
  input = gets.strip
  return default if input.empty?
  choice = input.to_i
  (1..options.size).include?(choice) ? choice : default
end

ROOT = Pathname.new(__dir__)
SCHEMA_PATH = ROOT / "sample_report" / "schema.json"
RLS_PATH = ROOT / "rls_config.json"
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"

def parse_execute_queries_rows(data)
  results = data["results"] || []
  return [] if results.empty?

  tables = results[0]["tables"] || []
  return [] if tables.empty?

  tables[0]["rows"] || []
end

def execute_query(token, query)
  url = "#{PBI_BASE}/groups/#{ENV['PBI_WORKSPACE_ID']}/datasets/#{ENV['PBI_DATASET_ID']}/executeQueries"
  body = {
    queries: [{ query: query }],
    serializerSettings: { includeNulls: true }
  }

  response = RestClient.post(url, body.to_json, {
    Authorization: "Bearer #{token}",
    content_type: :json,
    accept: :json
  })

  parse_execute_queries_rows(JSON.parse(response.body))
rescue RestClient::ExceptionWithResponse => e
  if e.response.code == 401
    fail "executeQueries returned 401 Unauthorized. Use delegated auth for DAX queries:"
    fail "- DAX_AUTH_MODE=azcli and run 'az login', or"
    fail "- DAX_AUTH_MODE=ropc with DAX_USER_EMAIL and DAX_USER_PASSWORD."
  end
  if e.response.code == 400
    warn "executeQueries returned 400 for query:\n#{query}"
    warn "Power BI response: #{e.response.body[0..1200]}"
  end
  raise e
end

def value_for_keys(row, candidates)
  key = row.keys.find do |k|
    normalized = k.to_s.gsub(/[\[\]'\"]/, '').downcase.strip
    candidates.any? { |c| normalized == c || normalized.gsub(/\s+/, '') == c.gsub(/\s+/, '') }
  end
  key ? row[key] : nil
end

def system_table?(table_name)
  table_name.start_with?("DateTableTemplate_") ||
    table_name.start_with?("LocalDateTable_") ||
    table_name.start_with?("AutoDateTable")
end

def discover_schema(token)
  column_query_candidates = [
    {
      label: "COLUMNSTATISTICS projected (Table Name/Column Name)",
      query: <<~DAX
        EVALUATE
        SELECTCOLUMNS(
          COLUMNSTATISTICS(),
          "TableName", [Table Name],
          "ColumnName", [Column Name]
        )
      DAX
    },
    {
      label: "COLUMNSTATISTICS raw",
      query: <<~DAX
        EVALUATE
        COLUMNSTATISTICS()
      DAX
    }
  ]

  measure_query_candidates = [
    {
      label: "INFO.MEASURES projected",
      query: <<~DAX
        EVALUATE
        SELECTCOLUMNS(
          INFO.MEASURES(),
          "TableName", [Table],
          "MeasureName", [Name]
        )
      DAX
    },
    {
      label: "TMSCHEMA_MEASURES DMV",
      query: <<~SQL
        SELECT * FROM $SYSTEM.TMSCHEMA_MEASURES
      SQL
    }
  ]

  column_rows = nil
  column_query_candidates.each do |candidate|
    info "Querying columns via #{candidate[:label]} ..."
    begin
      rows = execute_query(token, candidate[:query])
      if rows.any?
        column_rows = rows
        break
      end
      warn "#{candidate[:label]} returned 0 rows. Trying next option."
    rescue RestClient::ExceptionWithResponse => e
      warn "#{candidate[:label]} failed (#{e.response.code}). Trying next option."
    end
  end

  if column_rows.nil?
    fail "All column discovery queries failed. See warnings above for Power BI error details."
    exit 1
  end

  measure_rows = []
  measure_query_candidates.each do |candidate|
    info "Querying measures via #{candidate[:label]} ..."
    begin
      rows = execute_query(token, candidate[:query])
      if rows.any?
        measure_rows = rows
        break
      end
      warn "#{candidate[:label]} returned 0 rows. Trying next option."
    rescue RestClient::ExceptionWithResponse => e
      warn "#{candidate[:label]} failed (#{e.response.code}). Trying next option."
    end
  end

  table_map = Hash.new { |h, k| h[k] = { "name" => k, "columns" => [], "measures" => [] } }

  column_rows.each do |row|
    table_name = value_for_keys(row, ["tablename", "table", "table name"])
    column_name = value_for_keys(row, ["columnname", "column", "column name", "name", "explicitname"])

    if table_name.nil? && !column_name.nil?
      # Some metadata queries return fully-qualified columns like 'Sales'[Region].
      m = column_name.to_s.match(/^'?([^'\[]+)'?\[([^\]]+)\]$/)
      if m
        table_name = m[1]
        column_name = m[2]
      end
    end

    next if table_name.nil? || column_name.nil?

    table_name = table_name.to_s
    column_name = column_name.to_s
    next if table_name.empty? || column_name.empty? || system_table?(table_name)

    cols = table_map[table_name]["columns"]
    cols << column_name unless cols.include?(column_name)
  end

  measure_rows.each do |row|
    table_name = value_for_keys(row, ["tablename", "table", "table name"])
    measure_name = value_for_keys(row, ["measurename", "name", "measure name"])
    next if table_name.nil? || measure_name.nil?

    table_name = table_name.to_s
    measure_name = measure_name.to_s
    next if table_name.empty? || measure_name.empty? || system_table?(table_name)

    measures = table_map[table_name]["measures"]
    measures << measure_name unless measures.include?(measure_name)
  end

  tables = table_map.values.sort_by { |t| t["name"] }
  tables.each do |table|
    table["columns"].sort!
    table["measures"].sort!
  end

  { "tables" => tables }
end

def infer_rls_config(schema)
  identity_candidates = %w[upn email useremail userprincipalname username]
  filter_candidates = %w[region country department territory salesregion]

  identity_table = nil
  identity_column = nil
  filter_table = nil
  filter_column = nil

  (schema["tables"] || []).each do |table|
    table_name = table["name"].to_s
    columns = table["columns"] || []

    columns.each do |col|
      normalized = col.to_s.downcase
      if identity_table.nil? && identity_candidates.include?(normalized)
        identity_table = table_name
        identity_column = col
      end

      if filter_table.nil? && filter_candidates.include?(normalized)
        filter_table = table_name
        filter_column = col
      end
    end
  end

  enabled = !(identity_table.nil? || identity_column.nil? || filter_table.nil? || filter_column.nil?)

  {
    "enabled" => enabled,
    "identity_table" => identity_table || "",
    "identity_column" => identity_column || "",
    "filter_table" => filter_table || "",
    "filter_column" => filter_column || "",
    "description" => enabled ? "Auto-detected RLS mapping from schema." : "RLS mapping could not be auto-detected. Update this file manually."
  }
end

def get_azcli_token
  token_json = `az account get-access-token --resource https://api.fabric.microsoft.com/ --output json`
  unless $?.success?
    fail "Failed to get token from Azure CLI. Run 'az login' and retry."
    exit 1
  end
  JSON.parse(token_json)['accessToken']
rescue => e
  fail "Failed to parse Azure CLI token response: #{e.message}"
  exit 1
end

def get_ropc_token
  required = %w[AZURE_TENANT_ID AZURE_CLIENT_ID DAX_USER_EMAIL DAX_USER_PASSWORD]
  missing = required.select { |k| ENV[k].to_s.strip.empty? }
  if missing.any?
    fail "Missing environment variables for ROPC: #{missing.join(', ')}"
    exit 1
  end

  url = "https://login.microsoftonline.com/#{ENV['AZURE_TENANT_ID']}/oauth2/v2.0/token"
  payload = {
    grant_type: 'password',
    client_id: ENV['AZURE_CLIENT_ID'],
    username: ENV['DAX_USER_EMAIL'],
    password: ENV['DAX_USER_PASSWORD'],
    scope: 'https://api.fabric.microsoft.com/.default'
  }

  response = RestClient.post(url, payload)
  data = JSON.parse(response.body)
  token = data['access_token']
  if token.to_s.strip.empty?
    fail "ROPC token response did not include access_token."
    exit 1
  end
  token
rescue RestClient::ExceptionWithResponse => e
  fail "ROPC token failed #{e.response.code}: #{e.response.body}"
  exit 1
rescue => e
  fail "ROPC token failed: #{e.message}"
  exit 1
end

def dax_auth_mode
  (ENV['DAX_AUTH_MODE'] || 'azcli').downcase
end

def get_dax_token
  case dax_auth_mode
  when 'azcli'
    get_azcli_token
  when 'ropc'
    get_ropc_token
  else
    fail "Unknown DAX_AUTH_MODE '#{dax_auth_mode}'. Supported: azcli, ropc."
    exit 1
  end
end

# Main setup logic
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: setup.rb [options]"
  opts.on("--auto", "Skip prompts, accept best-guess defaults") do
    options[:auto] = true
  end
end.parse!

step(1, 3, "Validating environment")
required = %w[PBI_WORKSPACE_ID PBI_DATASET_ID]
missing = required.select { |k| ENV[k].nil? || ENV[k].empty? }
if missing.any?
  fail "Missing environment variables: #{missing.join(', ')}"
  exit 1
end
ok "Environment validated"

token = get_dax_token
ok "Delegated DAX token acquired via #{dax_auth_mode}"

step(2, 3, "Discovering Dataset Schema")
unless SCHEMA_PATH.dirname.exist?
  SCHEMA_PATH.dirname.mkpath
end

info "Fetching live schema from workspace #{ENV['PBI_WORKSPACE_ID']} dataset #{ENV['PBI_DATASET_ID']}..."
schema = discover_schema(token)

if schema["tables"].empty?
  fail "Schema discovery returned 0 tables. Verify workspace/dataset IDs and dataset permissions."
  exit 1
end

File.write(SCHEMA_PATH, JSON.pretty_generate(schema))
ok "Schema saved to #{SCHEMA_PATH} (#{schema['tables'].size} tables)"

step(3, 3, "Configuring RLS")
if RLS_PATH.exist? && !options[:auto]
  unless ask("rls_config.json already exists. Overwrite?", "n").downcase == 'y'
    ok "Keeping existing RLS config"
    exit 0
  end
end

# Heuristic detection based on discovered schema
rls_config = infer_rls_config(schema)
warn "Could not auto-detect RLS mapping. Review rls_config.json manually." unless rls_config["enabled"]

File.write(RLS_PATH, JSON.pretty_generate(rls_config))
ok "RLS configuration saved to #{RLS_PATH}"

puts "\n#{GREEN}#{BOLD}Setup complete!#{END_COLOR}"
info "You can now run the app with: #{BOLD}ruby app.rb#{END_COLOR}"
