# Diagnostics module

In iex: 

## Basic health check
CorroPort.DiagnosticTools.health_check()

## Full replication diagnostics  
CorroPort.DiagnosticTools.check_replication_state()

## Test propagation between nodes (if you have multiple running)
CorroPort.DiagnosticTools.test_message_propagation(8081, [8082, 8083])