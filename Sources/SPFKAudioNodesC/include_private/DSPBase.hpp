// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#import <CoreAudio/CoreAudioTypes.h>
#import <atomic>
#import <vector>

struct FrameRange {
    AUAudioFrameCount start;
    AUAudioFrameCount count;

    struct iterator {
        AUAudioFrameCount index;

        AUAudioFrameCount operator*() const { return index; }

        bool operator!=(const iterator &rhs) const {
            return index != rhs.index;
        }

        iterator &operator++() {
            ++index;
            return *this;
        }
    };

    iterator begin() { return {start}; }

    iterator end() { return {start + count}; }
};

/**
   Base class for DSPKernels. Many of the methods are virtual, because the base
   AudioUnit class does not know the type of the subclass at compile time.
 */

struct DSPBase {
  private:
    std::vector<AudioBufferList *> internalBufferLists;

  protected:
    int channelCount;
    double sampleRate;

    bool isInitialized = false;

    // current time in samples
    AUEventSampleTime now = 0;

    static constexpr int maxParameters = 128;

    class ParameterRamper *parameters[maxParameters];

    std::vector<AudioBufferList *> inputBufferLists;
    AudioBufferList *outputBufferList = nullptr;

    inline float &inputSample(int channel, AUAudioFrameCount frame) {
        return ((float *)inputBufferLists[0]->mBuffers[channel].mData)[frame];
    }

    inline float &outputSample(int channel, AUAudioFrameCount frame) {
        return ((float *)outputBufferList->mBuffers[channel].mData)[frame];
    }

    void stepRampsBy(AUAudioFrameCount frames);

    void zeroOutput(AUAudioFrameCount frames, AUAudioFrameCount bufferOffset);

  public:
    DSPBase(int inputBusCount = 1, bool canProcessInPlace = false);

    /// Virtual destructor allows child classes to be deleted with only DSPBase
    /// *pointer
    virtual ~DSPBase();

    AUInternalRenderBlock internalRenderBlock();

    const bool bCanProcessInPlace;

    std::atomic<bool> isBypassed{false};

    void setBuffer(AudioBufferList *buffer, size_t busIndex);

    size_t getInputBusCount() const { return inputBufferLists.size(); }

    /// Render function.
    virtual void process(FrameRange range) = 0;

    /// Uses the ParameterAddress as a key
    virtual void setParameter(AUParameterAddress address, float value,
                              bool immediate = false);

    /// Uses the ParameterAddress as a key
    virtual float getParameter(AUParameterAddress address);

    /// Get the DSP into initialized state
    virtual void reset() {}

    /// override this if your DSP kernel allocates memory or requires the
    /// session sample rate for initialization
    virtual void init(int channelCount, double sampleRate);

    /// override this if your DSP kernel allocates memory; free it here
    virtual void deinit();

    virtual void startRamp(const AUParameterEvent &event);

  private:
    /**
       Handles the event list processing and rendering loop. Should be called
       from AU renderBlock From Apple Example code
     */
    void processWithEvents(AudioTimeStamp const *timestamp,
                           AUAudioFrameCount frameCount,
                           AURenderEvent const *events);

    void processOrBypass(AUAudioFrameCount frameCount,
                         AUAudioFrameCount bufferOffset);

    void handleOneEvent(AURenderEvent const *event);

    void performAllSimultaneousEvents(AUEventSampleTime now,
                                      AURenderEvent const *&event);
};
