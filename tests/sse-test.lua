eventsReceived = 0

-- Called once per connection, before any request
function setup(thread)
  thread:set("eventsReceived", 0)
end

-- Called for each request/response cycle
function response(status, headers, body)
  -- Status will be 200 for a successful SSE connection
  if status == 200 then
    local currentEvents = thread:get("eventsReceived")
    thread:set("eventsReceived", currentEvents + 1)
  end
end

-- Called at the end of the test to print custom metrics
function done(summary, latency, requests)
  -- Convert values to strings implicitly with commas in print,
  -- or explicitly concatenate for io.write
  io.write("------------------------------\n")
  io.write("Total Duration:   " .. summary.duration .. " microseconds\n")
  io.write("Total Requests:   " .. summary.requests .. "\n")
  io.write("Total Bytes:      " .. summary.bytes .. "\n")
  io.write("------------------------------\n")
end
