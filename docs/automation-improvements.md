# Analytics Automation Improvements

This document outlines the automation improvements made to CorroPort for better analytics demonstration and debugging.

## 🚀 New Automation Script

### `scripts/analytics-demo.sh`

A comprehensive bash script that automates the entire analytics demonstration flow:

**Features:**
- ✅ Automated cluster setup with health checks
- ✅ HTTP API-based analytics control (with fallbacks)
- ✅ Intelligent message sending with retries
- ✅ Real-time results collection and display
- ✅ Colorized output with progress indicators
- ✅ Configurable parameters (nodes, messages, timing)
- ✅ Clean shutdown handling

**Usage:**
```bash
# Basic usage (2 nodes, 3 messages)
./scripts/analytics-demo.sh

# Custom configuration
./scripts/analytics-demo.sh 3 my_experiment 5 15
#                           ^nodes ^exp_id  ^msgs ^wait

# See all options
./scripts/analytics-demo.sh --help
```

**Example Output:**
```
🚀 CorroPort Analytics Demonstration
================================
Configuration:
  Nodes: 2
  Experiment ID: demo_20250622_153045
  Test Messages: 3
  Wait Time: 10s

→ Checking Corrosion agents...
✅ Corrosion agent 1 (port 8081) is running
✅ Corrosion agent 2 (port 8082) is running
```

## 🌐 New HTTP API Endpoints

### Analytics Control Endpoints

Added programmatic control endpoints for better automation:

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/analytics/aggregation/start` | Start analytics aggregation |
| `POST` | `/api/analytics/aggregation/stop` | Stop analytics aggregation |
| `GET` | `/api/analytics/aggregation/status` | Get aggregation status & active nodes |
| `POST` | `/api/messages/send` | Send test messages programmatically |

### Example Usage

**Start Aggregation:**
```bash
curl -X POST http://localhost:4001/api/analytics/aggregation/start \
  -H "Content-Type: application/json" \
  -d '{"experiment_id": "my_experiment"}'
```

**Send Message:**
```bash
curl -X POST http://localhost:4001/api/messages/send \
  -H "Content-Type: application/json" \
  -d '{"content": "Test message from API"}'
```

**Check Status:**
```bash
curl http://localhost:4001/api/analytics/aggregation/status | jq
```

### Benefits
- 🎯 **Programmatic Control**: No need to access iex shells
- 🔄 **Automation Friendly**: Easy integration with CI/CD
- 🌐 **Cross-Platform**: Works from any HTTP client
- 📊 **Structured Responses**: JSON with consistent error handling

## 🌊 Enhanced Tidewave Integration

### `scripts/tidewave-analytics.exs`

A specialized Tidewave configuration for analytics debugging:

**Features:**
- 🔍 **Function Watching**: Monitors key analytics functions
- 📊 **Process Monitoring**: Tracks analytics GenServers
- 🛠️ **Custom Commands**: Interactive debugging helpers
- 🏥 **Health Checking**: Automated cluster health validation

**New Tidewave Commands:**
```elixir
# Start a complete demo
analytics.start_demo()

# Send test messages
analytics.send_test_messages(5)

# Check system status
analytics.get_status()

# Validate cluster health
analytics.show_cluster_health()
```

**Loading the Configuration:**
```bash
# In iex session
iex> Code.eval_file("scripts/tidewave-analytics.exs")

# Or add to your .iex.exs
Code.eval_file("scripts/tidewave-analytics.exs")
```

### Tidewave Benefits
- 🐛 **Deep Debugging**: Function call tracing and inspection
- ⚡ **Interactive Testing**: Quick command-based experimentation
- 📈 **Real-time Monitoring**: Live process and state watching
- 🎛️ **Custom Tooling**: Domain-specific debugging commands

## 🎯 Usage Scenarios

### Scenario 1: Quick Demo for Stakeholders
```bash
# One command demonstration
./scripts/analytics-demo.sh 3 stakeholder_demo 10 20
```

### Scenario 2: CI/CD Integration
```bash
# Automated testing in CI
export EXPERIMENT_ID="ci_build_${BUILD_NUMBER}"
./scripts/analytics-demo.sh 2 "$EXPERIMENT_ID" 5 10

# Validate results via API
curl http://localhost:4001/api/analytics/experiments/$EXPERIMENT_ID/summary
```

### Scenario 3: Development Debugging
```bash
# Start cluster
./scripts/analytics-demo.sh

# In another terminal, use Tidewave
iex -S mix
iex> Code.eval_file("scripts/tidewave-analytics.exs")
iex> analytics.get_status()
```

### Scenario 4: Load Testing
```bash
# High-volume testing
./scripts/analytics-demo.sh 5 load_test 50 30
```

## 🔧 Implementation Details

### Error Handling
- **Graceful Degradation**: HTTP API calls fall back to mix run
- **Retry Logic**: Automatic retries for transient failures
- **Status Validation**: Health checks before proceeding
- **Clean Shutdown**: Proper cleanup on interrupt

### Configuration
- **Environment Variables**: Support for custom settings
- **Command Line Args**: Flexible parameter passing
- **Default Values**: Sensible defaults for quick usage
- **Validation**: Input validation with helpful error messages

### Logging & Output
- **Structured Output**: Clear progress indicators
- **Color Coding**: Visual distinction of status levels
- **JSON Processing**: Automatic pretty-printing where available
- **Debug Mode**: Verbose output option for troubleshooting

## 📊 Comparison: Before vs After

| Aspect | Before | After |
|--------|---------|-------|
| **Setup Time** | ~5 minutes manual | ~30 seconds automated |
| **Consistency** | Manual steps vary | Identical every time |
| **Error Prone** | High (many manual steps) | Low (automated validation) |
| **Debugging** | Basic logging only | Tidewave + HTTP APIs |
| **Integration** | Manual only | CI/CD ready |
| **Documentation** | Scattered | Centralized + examples |

## 🚀 Future Improvements

### Potential Enhancements
1. **Docker Integration**: Containerized demo environment
2. **Grafana Dashboard**: Visual analytics monitoring
3. **Load Testing Suite**: Automated performance testing
4. **Multi-Region Demo**: Geographic distribution simulation
5. **Chaos Testing**: Failure scenario automation

### Tidewave Extensions
1. **Custom Visualizations**: Real-time graphs and charts
2. **Automated Alerts**: Threshold-based notifications
3. **Performance Profiling**: Detailed timing analysis
4. **State Snapshots**: Capture and replay system states

## 📚 Related Files

- `scripts/analytics-demo.sh` - Main automation script
- `scripts/tidewave-analytics.exs` - Tidewave configuration
- `lib/corro_port_web/controllers/analytics_api_controller.ex` - HTTP API endpoints
- `lib/corro_port_web/router.ex` - API routing configuration
- `CLAUDE.md` - Updated development commands

This automation infrastructure makes CorroPort analytics much more accessible for development, testing, and demonstration purposes!