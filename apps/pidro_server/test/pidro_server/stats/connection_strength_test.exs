defmodule PidroServer.Stats.ConnectionStrengthTest do
  use PidroServer.DataCase, async: true

  alias PidroServer.Stats

  test "connection grades require ten minutes and both latency and drop thresholds" do
    grade = fn seconds, median, drops ->
      Stats.connection_grade(%{duration_seconds: seconds, median_ms: median, drops: drops})
    end

    assert grade.(599, 30, 0) == :insufficient
    assert grade.(600, 30, 0) == :good
    assert grade.(3600, nil, 0) == :insufficient
    assert grade.(3600, 149, 0) == :good
    assert grade.(3600, 150, 0) == :fair
    assert grade.(3600, 30, 1) == :fair
    assert grade.(3600, 399, 3) == :fair
    assert grade.(3600, 400, 0) == :poor
    assert grade.(3600, 30, 4) == :poor
    assert grade.(7200, 30, 1) == :good
  end
end
