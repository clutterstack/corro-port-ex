defmodule CorroPortWeb.AnalyticsLive.HelpersTest do
  use ExUnit.Case, async: true

  alias CorroPortWeb.AnalyticsLive.Helpers

  describe "latency_colour_class/1" do
    test "returns green for latency under 300ms" do
      assert Helpers.latency_colour_class(299) == "text-green-600 font-medium"
    end

    test "returns yellow for latency between 300ms and 600ms" do
      assert Helpers.latency_colour_class(450) == "text-yellow-600 font-medium"
    end

    test "returns orange for latency between 600ms and 900ms" do
      assert Helpers.latency_colour_class(750) == "text-orange-600 font-medium"
    end

    test "returns red for latency 900ms or higher" do
      assert Helpers.latency_colour_class(900) == "text-red-600 font-medium"
    end

    test "returns grey for non-numeric values" do
      assert Helpers.latency_colour_class(nil) == "text-gray-600"
    end
  end
end
