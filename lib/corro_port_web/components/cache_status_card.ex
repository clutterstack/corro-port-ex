defmodule CorroPortWeb.CacheStatusCard do
  use Phoenix.Component
  import CorroPortWeb.CoreComponents

  @doc """
  Renders cache status card displaying DNS, CLI, and API data source status.
  """
  attr :cache_status, :map, required: true

  def cache_status_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <h4 class="text-sm font-semibold mb-3 flex items-center gap-2">
          <.icon name="hero-clock" class="w-4 h-4" /> Data Source Status
        </h4>
        <div class="grid md:grid-cols-3 gap-4 text-xs">
          <div class="flex items-start gap-2">
            <.icon name="hero-globe-alt" class="w-4 h-4 mt-0.5 text-primary" />
            <div>
              <div class="font-semibold">DNS Discovery</div>
              <div class="text-base-content/70">{@cache_status.dns}</div>
            </div>
          </div>

          <div class="flex items-start gap-2">
            <.icon name="hero-command-line" class="w-4 h-4 mt-0.5 text-secondary" />
            <div>
              <div class="font-semibold">CLI Members</div>
              <div class="text-base-content/70">{@cache_status.cli}</div>
            </div>
          </div>

          <div class="flex items-start gap-2">
            <.icon name="hero-server" class="w-4 h-4 mt-0.5 text-accent" />
            <div>
              <div class="font-semibold">Corrosion API</div>
              <div class="text-base-content/70">{@cache_status.api}</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
