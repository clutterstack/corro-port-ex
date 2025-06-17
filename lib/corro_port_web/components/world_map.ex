defmodule CorroPortWeb.WorldMap do
  use Phoenix.Component
  require Logger

  import CorroPort.CityData

  @bbox {0, 0, 800, 391}
  @minx 0
  @miny 10
  @w 800
  @h 320

  attr :minx, :integer, default: @minx
  attr :miny, :integer, default: @miny
  attr :maxx, :integer, default: @minx + @w
  attr :maxy, :integer, default: @miny + @h
  attr :viewbox, :string, default: "#{@minx} #{@miny} #{@w} #{@h}"
  attr :toppath, :string, default: "M #{@minx + 1} #{@miny + 0.5} H #{@w - 0.5}"
  attr :btmpath, :string, default: "M #{@minx + 1} #{@miny + @h - 1} H #{@w - 0.5}"
  attr :muted, :string, default: "#DAA520"
  attr :dull, :string, default: "#add3ff" #"#b58b22"
  attr :bright, :string, default: "#ffdc66"

  # Render the world map SVG
  def world_map_svg(assigns) do
    # "0 0 800 391"
    ~H"""
    <svg viewBox={@viewbox} stroke-linecap="round" stroke-linejoin="round"  xmlns="http://www.w3.org/2000/svg" phx-hook="WorldMap" id="region-map">
      <defs>
        <!-- Radial gradient for blue markers -->
        <radialGradient id="blueRadial" cx="50%" cy="50%" r="50%" fx="50%" fy="50%">
          <stop offset="60%" stop-color="#77b5fe" stop-opacity="1"/>
          <stop offset="80%" stop-color="#77b5fe" stop-opacity="0.6"/>
          <stop offset="100%" stop-color="#77b5fe" stop-opacity="0.2"/>
        </radialGradient>
      </defs>

      <style>
        circle {
          pointer-events: none;
        }
        .region-group text {
          opacity: 0;
          stroke: <%= @bright %>;
          fill: <%= @bright %>;
          transition: opacity 0.2s;
          pointer-events: none;
          user-select: none;
        }
        .region-group:hover text,
        .region-group.active text {
          opacity: 1;
        }
        .region-group circle {
          stroke: transparent;
          fill: <%= @dull %>;
          stroke-width: 8;
          pointer-events: all;
        }
        .region-group:hover circle {
          stroke: <%= @bright %>;
          fill: <%= @bright %>;
        }
      </style>

      <g id="ne_110m_ocean">
        <path d="M 508.86 108.99 503.48 101.62 513.48 96.21 517.58 96.64 517.57 100.18 511.51 101.61 513.81 104.89 521.33 109.73 517.3 109.89 519.31 118.56 512.7 118.77 509.06 117.19 508.86 108.99 Z"
          stroke="#DAA520"
          stroke-width="1"
          fill="#444444"
          fill-rule="evenodd"
        />
      </g>

      <path d={@toppath} stroke="#DAA520"
          stroke-width="1" />

      <path d={@btmpath} stroke="#DAA520"
          stroke-width="1" />

      <%= for {region, {x, y}} <- all_regions_with_coords() do %>
        <g class="region-group" id={"region-#{region}"}>
          <circle cx={x} cy={y} r="2" opacity="0.9" />
          <text x={x} y={y - 8} text-anchor="middle" font-size="20" ><%= region %></text>
        </g>
      <% end %>

      <%= for {x, y} <- coords(@regions) do %>
        <circle cx={x} cy={y} r="6" fill="#ffdc66" opacity="0.9" />
      <% end %>

      <%= for {x, y} <- coords(@our_regions) do %>

      <!-- Outer gradient circle with animation -->
        <circle
          cx={x}
          cy={y}
          stroke="none"
          fill="url(#blueRadial)">
          <animate attributeName="r" values="8;12;8" dur="3s" repeatCount="indefinite" />
        </circle>

      <% end %>

    </svg>
    """
    # <animate attributeName="opacity" values="0.7;1;0.7" dur="2s" repeatCount="indefinite" />

  end

  @doc """
  Get coordinates for active regions to display on the map
  """
  def coords(regions) do
    # Convert region codes to coordinates for the map
    regions
    |> Enum.map(fn region -> city_to_svg(region, @bbox) end)
  end


  def city_to_svg("unknown", _bbox) do
  {-1, -1}
end

def city_to_svg(city, bbox) when city != "unknown" do
  case CorroPort.CityData.get_coordinates(city) do
    {long, lat} -> wgs84_to_svg({long, lat}, bbox)
    nil ->
      Logger.warning("WorldMap: Region '#{city}' not found in cities map")
      {-1, -1}  # Return off-screen coordinates
  end
end

  def all_regions_with_coords() do
    for {city, coords} <- cities() do
      {city, wgs84_to_svg(coords, @bbox)}
    end
  end

  def all_svg_coords() do
    for {city, coords} <- cities(), into: %{} do
      wgs84_to_svg(coords, @bbox)
    end
  end

  @doc """
    Transforms WGS84 (EPSG:4326) lat/long coordinates to SVG x/y positions.

    Parameters:
    - lat: Latitude in degrees
    - long: Longitude in degrees
    - svg_width: Width of the SVG in pixels
    - svg_height: Height of the SVG in pixels
    - bounds: Map with geographic bounds in format:
              %{min_long: value, max_long: value, min_lat: value, max_lat: value}

    Returns {x, y} coordinates in the SVG space
    """
    def wgs84_to_svg({long, lat}, {x_min, y_min, x_max, y_max}) do
      svg_width = x_max - x_min
      svg_height = y_max - y_min

      bounds=%{min_long: -180, max_long: 180, min_lat: -90, max_lat: 90}

      # Calculate percentage position along each axis
      x_percent = (long - bounds.min_long) / (bounds.max_long - bounds.min_long)

      # Note the inversion for y-axis since SVG's y increases downward
      # while latitude increases upward
      y_percent = 1 - (lat - bounds.min_lat) / (bounds.max_lat - bounds.min_lat)

      # Convert to pixel positions
      x = x_percent * svg_width
      y = y_percent * svg_height

      {x, y}
    end


end
