# Sprint 2 Research Plan

## Overview
With Issue #6 Phase A complete (real audio capture working), we can now start Sprint 2 research tasks in parallel.

## Issue #3: Research Core Audio Driver Architecture
**Goal:** Understand how to capture system-wide audio on macOS
**Duration:** 2-3 weeks
**Owner:** Keith (with AI assistance)

### Research Topics:
1. **Audio Unit Extensions vs HAL Driver**
   - What are the differences?
   - Which is better for system-wide capture?
   - What are the trade-offs?

2. **System Audio Capture Methods**
   - BlackHole architecture analysis
   - SoundFlower approach
   - Apple's Core Audio framework capabilities

3. **Permission & Security Requirements**
   - What permissions needed for system audio?
   - Sandboxing implications
   - Code signing requirements

4. **Performance Considerations**
   - Latency requirements (<10ms)
   - Buffer management strategies
   - CPU usage optimization

### Deliverables:
- [ ] Technical report (3-5 pages)
- [ ] Architecture decision document
- [ ] Prototype code samples
- [ ] Performance benchmarks

## Issue #5: Research DeepFilterNet Model
**Goal:** Evaluate DeepFilterNet for Core ML conversion
**Duration:** 2-3 weeks
**Owner:** AI Agent (with Keith oversight)

### Research Topics:
1. **Model Architecture Analysis**
   - DeepFilterNet structure
   - Input/output specifications
   - Model size and complexity

2. **Core ML Conversion Feasibility**
   - PyTorch → Core ML pipeline
   - Conversion tools (coremltools)
   - Apple Neural Engine compatibility

3. **Performance Expectations**
   - Latency estimates
   - Memory requirements
   - Quality vs performance trade-offs

4. **Optimization Opportunities**
   - Quantization (INT8/FP16)
   - Pruning possibilities
   - ANE-specific optimizations

### Deliverables:
- [ ] Model analysis report (3-5 pages)
- [ ] Conversion plan document
- [ ] Performance targets
- [ ] Risk assessment

## Parallel Execution Strategy

### Week 1-2: Initial Research
**Keith (Issue #3):**
- Research Audio Unit Extensions
- Analyze BlackHole/SoundFlower
- Document permission requirements

**AI Agent (Issue #5):**
- Analyze DeepFilterNet architecture
- Research Core ML conversion tools
- Document ANE compatibility

### Week 3: Deep Dives
**Keith:**
- Prototype basic audio capture
- Test latency and performance
- Draft architecture decision

**AI Agent:**
- Create conversion pipeline plan
- Benchmark performance estimates
- Identify optimization opportunities

### Week 4: Reports & Planning
**Keith:**
- Complete technical report
- Present architecture recommendation
- Start Issue #4 planning

**AI Agent:**
- Complete model analysis report
- Define conversion acceptance criteria
- Start Issue #10 planning

## Success Criteria
- [ ] Both research reports complete
- [ ] Architecture decisions documented
- [ ] Performance targets validated
- [ ] Ready to start implementation (Issues #4, #10)

## Next Steps After Research
With research complete, Sprint 2 continues with:
- **Issue #4**: Implement Core Audio Loopback Driver
- **Issue #10**: Core ML Conversion and ANE Optimization
- **Issue #7**: Menu Bar Interface enhancements

This sets up Sprint 3 for integration work.
