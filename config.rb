require 'dotenv/load'
require 'json'
require 'pathname'
require 'logger'


module Settings
  extend self

  def logger
    @logger ||= Logger.new(STDOUT).tap { |l| l.level = Logger::INFO }
  end

  def azure_tenant_id
    ENV['AZURE_TENANT_ID']
  end

  def azure_client_id
    ENV['AZURE_CLIENT_ID']
  end

  def azure_client_secret
    ENV['AZURE_CLIENT_SECRET']
  end

  def pbi_workspace_id
    ENV['PBI_WORKSPACE_ID']
  end

  def pbi_report_id
    ENV['PBI_REPORT_ID']
  end

  def pbi_dataset_id
    ENV['PBI_DATASET_ID']
  end

  def pbi_rls_role
    ENV['PBI_RLS_ROLE'] || 'ViewerRole'
  end

  # README-aligned auth modes for executeQueries.
  # default_credential maps to Azure CLI token in this Ruby implementation.
  def dax_auth_mode
    (ENV['DAX_AUTH_MODE'] || 'default_credential').downcase
  end

  def dax_user_email
    ENV['DAX_USER_EMAIL'] || ''
  end

  def dax_user_password
    ENV['DAX_USER_PASSWORD'] || ''
  end

  def azure_openai_endpoint
    ENV['AZURE_OPENAI_ENDPOINT']
  end

  def azure_openai_api_key
    ENV['AZURE_OPENAI_API_KEY'] || ''
  end

  def azure_openai_deployment
    ENV['AZURE_OPENAI_DEPLOYMENT'] || 'gpt-4o'
  end

  def azure_openai_api_version
    ENV['AZURE_OPENAI_API_VERSION'] || '2024-12-01-preview'
  end

  def azure_openai_max_tokens
    (ENV['AZURE_OPENAI_MAX_TOKENS'] || '900').to_i
  end

  def summary_row_limit
    (ENV['SUMMARY_ROW_LIMIT'] || '50').to_i
  end

  def enable_project_shortcuts
    ENV['ENABLE_PROJECT_SHORTCUTS'].to_s.strip.downcase == 'true'
  end

  def fabric_agent_instructions
    @fabric_agent_instructions ||= begin
      configured = ENV['FABRIC_AGENT_INSTRUCTIONS_FILE'].to_s.strip
      path = if configured.empty?
        Pathname.new(__dir__) / 'fabric_agent_instructions.txt'
      else
        Pathname.new(configured)
      end

      if path.exist?
        File.read(path).to_s.strip
      else
        logger.warn "Fabric instructions file not found at #{path}; using built-in defaults."
        default_fabric_agent_instructions
      end
    rescue => e
      logger.warn "Failed loading Fabric instructions: #{e.class} - #{e.message}. Using built-in defaults."
      default_fabric_agent_instructions
    end
  end

  # Fallback for environments without API key.
  def azure_openai_bearer_token
    token_json = `az account get-access-token --resource https://cognitiveservices.azure.com/ --output json`
    return '' unless $?.success?

    JSON.parse(token_json)['accessToken'].to_s
  rescue
    ''
  end

  def app_secret_key
    ENV['APP_SECRET_KEY'] || 'change-me'
  end

  def demo_users
    @demo_users ||= begin
      raw = ENV['DEMO_USERS']
      if raw
        JSON.parse(raw)
      else
        {
          "Rithika Musku" => "rmusku@itagroup.com",
          "Andrew Slagle" => "aslagle@itagroup.com",
          "Gurdish Kaur" => "gkaur@itagroup.com"
        }
      end
    end
  end

  def rls_config
    @rls_config ||= load_rls_config
  end

  private

  def load_rls_config
    config_path = Pathname.new(__dir__) / 'rls_config.json'
    unless config_path.exist?
      logger.warn 'rls_config.json not found; chat RLS filter instructions are disabled.'
      return { 'enabled' => false }
    end

    raw = JSON.parse(File.read(config_path))
    {
      'enabled' => raw.fetch('enabled', true),
      'identity_table' => raw.fetch('identity_table', ''),
      'identity_column' => raw.fetch('identity_column', ''),
      'filter_table' => raw.fetch('filter_table', ''),
      'filter_column' => raw.fetch('filter_column', ''),
      'custom_lookup_dax' => raw.fetch('custom_lookup_dax', nil),
      'description' => raw.fetch('description', '')
    }
  rescue => e
    logger.error "Failed to parse rls_config.json: #{e.class} - #{e.message}"
    { 'enabled' => false }
  end

  def default_fabric_agent_instructions
    <<~TEXT.strip
      Use [Date].[TodaysDate] as today's date.
      When asked about utilization, use [Fact_AllHours].[_Util+ %] values rounded to two decimal points.
      Always provide utilization percents for each Expense Type from [Dim_Task].[Expense Type].
      Always return [Dim_User].[Username] as the user.
      When asked for Fiscal Year to Date (FYTD), only include data through the end of the prior month from today's date.
      Fiscal years start on September 1 and end on August 31.
      Tell the user what date range was used in the output.
      When asked for members reporting to a manager, find the manager in [Dim_User].[Name], then use the corresponding [Dim_User].[UserId] to find direct reports where [Dim_User].[ManagerId] matches.
      Create a table with User and each Expense Type as column headers when returning utilization-style breakdowns.
      When asked about a Department, use [Dim_User].[Deparment] or [Dim_User].[DepartmentCode].
    TEXT
  end
end
