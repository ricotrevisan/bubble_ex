# BubbleEx Development Plan

## Phase 0: Stabilization (Immediate Priority)
**Goal:** Get a green test suite and establish stable foundation

### 1. Fix Failing Tests
- [ ] Analyze test failures (timeouts, assertion errors, crashes)
- [ ] Decide if they deserve to exist
- [ ] Tag integration ones with `:integration`
- [ ] For Integration tests, ensure that we have enough actual samples to test them.
- [ ] Add proper mocking with `Mox` for external dependencies
- [ ] Create `BubbleEx.HTTPClient` behavior for HTTP operations
- [ ] Create `BubbleEx.Secrets.Scanner` behavior for secret scanning
- [ ] Fix unused variable warnings in tests

### 2. External Dependency Management
- [ ] Make trufflehog CLI optional rather than required
- [ ] Implement fallback when trufflehog not available
- [ ] Add proper error handling for missing external tools

## Phase 1: Core Architecture Improvements
**Goal:** Address fundamental reliability and security issues

### 1. Error Handling Standardization
- [ ] Create `BubbleEx.Error` exception struct with type, reason, metadata
- [ ] Replace all `{:error, reason}` tuples with structured errors
- [ ] Add comprehensive error documentation for all public functions

### 2. Security Hardening
- [ ] Replace `System.cmd` with secure argument passing (avoid shell injection)
- [ ] Implement safe temporary file handling with cleanup
- [ ] Add input validation and sanitization for all external inputs
- [ ] Use HTTPS everywhere, remove any hardcoded HTTP URLs

### 3. Configuration System
- [ ] Add configuration validation on application start
- [ ] Make all timeouts configurable
- [ ] Support custom HTTP client injection
- [ ] Validate required dependencies and provide clear error messages

## Phase 2: Public API & Documentation
**Goal:** Create clear, stable public interface

### 1. API Surface Definition
- [ ] Mark private functions with `@moduledoc false` and `@doc false`
- [ ] Add comprehensive `@doc` and `@spec` to all public functions
- [ ] Create consistent naming patterns across modules
- [ ] Remove internal functions from module exports

### 2. Documentation
- [ ] Add detailed function examples in `@doc`
- [ ] Create comprehensive getting started guide
- [ ] Document all configuration options
- [ ] Add troubleshooting section for common issues
- [ ] Generate proper ExDoc documentation

## Phase 3: Secret Scanning Redesign
**Goal:** Replace external trufflehog dependency

### 1. Pure Elixir Secret Scanner
- [ ] Implement `BubbleEx.Secrets` module with configurable regex patterns
- [ ] Support common secret formats (API keys, tokens, private keys)
- [ ] Make scanner adapter-based for future extensibility
- [ ] Add entropy-based detection for unknown secrets

### 2. Trufflehog Integration (Optional)
- [ ] Move trufflehog to optional separate adapter
- [ ] Use Erlang Port for robust process management if needed
- [ ] Implement proper supervision and crash handling

## Phase 4: Testing & Quality
**Goal:** Comprehensive test coverage and reliability

### 1. Test Infrastructure
- [ ] Mock all external dependencies (HTTP, CLI tools)
- [ ] Add integration tests with real Bubble.io apps (tagged separately)
- [ ] Implement property-based testing for parsing logic
- [ ] Add performance benchmarks for critical paths

### 2. Code Quality
- [ ] Add Dialyzer specs and fix all warnings
- [ ] Implement Credo for code consistency
- [ ] Add comprehensive type checking
- [ ] Extract common patterns to reduce duplication

## Phase 5: Performance & Production Features
**Goal:** Optimize for production use

### 1. Performance Optimization
- [ ] Implement HTTP connection pooling with Finch
- [ ] Add streaming support for large JSON payloads
- [ ] Implement proper backpressure for bulk operations
- [ ] Add configurable retry mechanisms with exponential backoff

### 2. Monitoring & Observability
- [ ] Add telemetry events for all major operations
- [ ] Implement structured logging throughout
- [ ] Add health check endpoints for server components
- [ ] Support custom metrics collection

## Implementation Notes
- **Risk Mitigation:** Phase 0 must complete before any other work
- **Testing Strategy:** All new code requires tests before merge
- **Backward Compatibility:** Maintain existing public API during refactoring
- **Documentation:** Update docs with each phase completion
- **Security:** Security review required before Phase 5 completion

## Success Metrics
- All tests passing (Phase 0)
- Zero Dialyzer warnings (Phase 4)
- Complete API documentation (Phase 2)
- No external CLI dependencies required (Phase 3)
- Production-ready performance (Phase 5)

---

# Original Todo Items (Reference)

## High Priority - Library Essentials

### Public API & Documentation
- [ ] **Create comprehensive API documentation** - Add detailed @doc for all public functions
- [ ] **Define clear public API surface** - Mark private functions explicitly, clean up exports
- [ ] **Add getting started guide** - Include installation, basic usage examples in README
- [ ] **Document configuration options** - How users configure timeouts, API keys, etc.
- [ ] **Add function examples** - @doc with real usage examples for each public function

### Error Handling & Reliability
- [ ] **Standardize error tuple formats** - Consistent `{:ok, result} | {:error, reason}` across all public functions
- [ ] **Create custom error structs** - Replace generic error atoms with structured errors
- [ ] **Add error documentation** - Document all possible error conditions for each function
- [ ] **Handle external dependencies gracefully** - Clear errors when trufflehog CLI missing

### Configuration & Flexibility
- [ ] **Make external tool dependencies optional** - Allow library to work even if trufflehog not installed
- [ ] **Add configuration validation** - Validate config on application start
- [ ] **Support custom HTTP client** - Allow users to inject their own HTTP client
- [ ] **Make timeouts configurable** - Don't hardcode timeout values

## Medium Priority - User Experience

### Testing & Quality
- [ ] **Add comprehensive test suite** - Ensure all public functions have tests
- [ ] **Mock external dependencies** - Don't make real HTTP calls in tests
- [ ] **Add integration examples** - Show how to use library in real projects
- [ ] **Test with different Elixir versions** - Ensure compatibility

### Performance & Scalability
- [ ] **Add connection pooling** - Reuse HTTP connections efficiently
- [ ] **Handle large payloads** - Stream processing for big JSON responses
- [ ] **Add timeout controls** - Configurable timeouts for all operations
- [ ] **Implement backpressure** - Handle rate limiting gracefully

### Security
- [ ] **Use HTTPS everywhere** - No hardcoded HTTP URLs
- [ ] **Sanitize all inputs** - Validate app names, URLs before use
- [ ] **Secure temp file handling** - Clean up temporary files properly
- [ ] **Safe command execution** - Avoid shell injection in trufflehog adapter

## Low Priority - Nice to Have

### Features
- [ ] **Add retry mechanisms** - Automatic retry for failed requests with backoff
- [ ] **Implement caching layer** - Optional caching for expensive operations
- [ ] **Add telemetry events** - Allow users to monitor library usage
- [ ] **Support batch operations** - Analyze multiple apps efficiently

### Code Quality
- [ ] **Reduce code duplication** - Extract common HTTP/URL building patterns
- [ ] **Improve module organization** - Better separation of concerns
- [ ] **Add type specs everywhere** - Full Dialyzer compatibility
- [ ] **Performance benchmarks** - Measure and optimize hot paths

## Library-Specific Considerations

### Dependencies
- [ ] **Audit dependencies** - Minimize required deps, make some optional
- [ ] **Version compatibility** - Test with supported Elixir/OTP versions
- [ ] **Dependency documentation** - Clear about what external tools are needed

### Packaging
- [ ] **Hex package metadata** - Proper description, keywords, links
- [ ] **Semantic versioning** - Clear versioning strategy for breaking changes
- [ ] **Changelog maintenance** - Document changes between versions
- [ ] **CI/CD pipeline** - Automated testing and publishing

### Examples & Guides
- [ ] **Usage patterns documentation** - Common use cases and how to implement them
- [ ] **Troubleshooting guide** - Common issues and solutions
- [ ] **Phoenix integration example** - Show how to use in web applications
- [ ] **Script usage examples** - Command-line usage patterns

## Breaking Changes to Consider

### API Cleanup
- [ ] **Consistent function naming** - Review all public function names
- [ ] **Remove internal functions from exports** - Clean module interfaces
- [ ] **Standardize return values** - All functions should have predictable return patterns
- [ ] **Configuration structure** - Design clean config interface before 1.0
