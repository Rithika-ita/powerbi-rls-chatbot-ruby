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
    ENV['PBI_RLS_ROLE'] || "ViewerRole"
  end

  def dax_auth_mode
    ENV['DAX_AUTH_MODE']&.downcase || "azcli"
  end

  def dax_user_email
    ENV['DAX_USER_EMAIL'] || ""
  end

  def dax_user_password
    ENV['DAX_USER_PASSWORD'] || ""
  end

  def foundry_endpoint
    ENV['FOUNDRY_ENDPOINT']
  end

  def foundry_model
    ENV['FOUNDRY_MODEL']
  end

  def foundry_agent_id
    ENV['FOUNDRY_AGENT_ID']
  end

  def foundry_scope
    # Foundry project endpoints expect audience https://ai.azure.com
    ENV['FOUNDRY_SCOPE'] || 'https://ai.azure.com/.default'
  end

  def foundry_rls_context_mode
    (ENV['FOUNDRY_RLS_CONTEXT_MODE'] || 'plain').downcase
  end

  def foundry_reuse_threads?
    raw = (ENV['FOUNDRY_REUSE_THREADS'] || 'false').downcase
    %w[1 true yes on].include?(raw)
  end

  def use_foundry_endpoint?
    true  # Always Foundry-only for this deployment
  end

  def app_secret_key
    ENV['APP_SECRET_KEY'] || "change-me"
  end

  def demo_users
    @demo_users ||= begin
      raw = ENV['DEMO_USERS']
      if raw
        JSON.parse(raw)
      else
        {
          "Alice (West Region)" => "rmusku@itagroup.com",
          "Bob (East Region)" => "aslagle@ITAGROUP.com",
          "Carlos (All Regions)" => "carlos@contoso.com"
        }
      end
    end
  end

  # Per-user passwords for ROPC → OBO flow.
  # Stored as JSON in USER_PASSWORDS env var:
  #   USER_PASSWORDS={"user@domain.com":"password1","user2@domain.com":"password2"}
  def user_passwords
    @user_passwords ||= begin
      raw = ENV['USER_PASSWORDS']
      raw ? JSON.parse(raw) : {}
    rescue => e
      logger.error "Failed to parse USER_PASSWORDS: #{e.message}"
      {}
    end
  end

  def user_password_for(email)
    user_passwords[email]
  end

  def rls_config
    @rls_config ||= load_rls_config
  end

  private

  def load_rls_config
    config_path = Pathname.new(__dir__) / "rls_config.json"
    unless config_path.exist?
      logger.warn "rls_config.json not found — DAX queries will run WITHOUT RLS filtering. Copy rls_config.example.json → rls_config.json and customise it."
      return { "enabled" => false }
    end

    begin
      raw = JSON.parse(File.read(config_path))
      config = {
        "enabled" => raw.fetch("enabled", true),
        "identity_table" => raw.fetch("identity_table", ""),
        "identity_column" => raw.fetch("identity_column", ""),
        "filter_table" => raw.fetch("filter_table", ""),
        "filter_column" => raw.fetch("filter_column", ""),
        "custom_lookup_dax" => raw.fetch("custom_lookup_dax", nil),
        "description" => raw.fetch("description", "")
      }
      if config["enabled"]
        logger.info "RLS config loaded: filter on #{config["filter_table"]}[#{config["filter_column"]}] via #{config["identity_table"]}[#{config["identity_column"]}]"
      end
      config
    rescue => e
      logger.error "Failed to parse rls_config.json: #{e}"
      { "enabled" => false }
    end
  end
end
