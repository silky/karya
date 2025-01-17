// Copyright 2018 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#pragma once

#include <atomic>
#include <string>
#include <memory>
#include <thread>
#include <vector>

#include "Audio.h"
#include "Semaphore.h"
#include "ringbuffer.h"


// Stream samples from disk.
//
// This has a realtime and a non-realtime API.  The class must be created in a
// non-realtime context, at which point it starts up stream_thread which will
// handle non-realtime work.  The public methods, specifically read(), should
// then be realtime-safe.
//
// A subclass is expected to provide a start() method and override
// initialize().  The reason for the two step initialization is that start()
// is called in a realtime context, and just copy its arguments to
// pre-allocated storage, while initialize() is called from the non-realtime
// thread.
class Streamer : public Audio {
protected:
    Streamer(const char *name, std::ostream &log, int channels, int sample_rate,
        int max_frames, bool synchronized);
public:
    virtual ~Streamer();

    // Return true if the read is done, and there are no samples in 'out'.
    bool read(int channels, Frames frames, float **out) override;

    const int channels;
    const int sample_rate;
    const int max_frames;
protected:
    const char *name;
    std::ostream &log;

    // ** stream thread state
    void restart();
    // Called on non-realtime thread.
    virtual Audio *initialize() = 0;
private:
    void stream_loop();
    void stream();
    std::unique_ptr<std::thread> stream_thread;
    std::unique_ptr<Audio> audio;

    // ** communication with stream_thread.
    std::atomic<bool> thread_quit;
    // Goes to true when the Audio has run out of data.
    std::atomic<bool> audio_done;
    // Set to true to have the stream_thread reload mix.
    std::atomic<bool> restarting;
    jack_ringbuffer_t *ring;
    // ring needs more data.
    Semaphore ready;

    // ** read() state

    // This is true for streaming from the cache and false for the OSC "MIDI
    // thru" mechanism.  For thru, it doesn't matter that samples are
    // synchronized to any start time, I just start streaming them when I get
    // them.
    const bool synchronized;
    // Keep track if read() position gets ahead of what ring was able to
    // provide.
    Frames debt;
    std::vector<float> output_buffer;
};


class TracksStreamer : public Streamer {
public:
    TracksStreamer(std::ostream &log, int channels, int sample_rate,
        int max_frames);
    void start(const std::string &dir, Frames start_offset,
        const std::vector<std::string> &mutes);

private:
    // Statically allocated state start() passes to stream_loop().
    struct {
        std::string dir;
        Frames start_offset;
        std::vector<std::string> mutes;
    } args;
    Audio *initialize() override;
};


class ResampleStreamer : public Streamer {
public:
    ResampleStreamer(std::ostream &log, int channels, int sample_rate,
            int max_frames);
    void start(const std::string &fname, int64_t offset, double ratio);
    void stop();

private:
    std::string fname;
    int64_t offset;
    double ratio;
    Audio *initialize() override;
};


class MixStreamer : public Audio {
public:
    MixStreamer(
        int max_voices, std::ostream &log, int channels, int sample_rate,
        int max_frames);
    void start(int voice, const std::string &fname, int64_t offset,
        double ratio, float volume);
    void stop();

    // Return true if the read is done, and there are no samples in 'out'.
    bool read(int channels, Frames frames, float **out) override;

private:
    std::vector<std::unique_ptr<ResampleStreamer>> voices;
    std::vector<float> volumes;
    std::vector<float> buffer;
};
