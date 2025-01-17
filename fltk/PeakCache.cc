// Copyright 2019 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#include <chrono>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include "PeakCache.h"
#include "types.h"
#include "util.h"

// TODO: this should be a separate library, but it's annoying to do while my
// shakefile setup is a mess.
#include "Synth/play_cache/Wav.h"

// for SAMPLING_RATE.
#include "Synth/Shared/config.h"


enum {
    // Store a max value at this sampling rate.  This should be small enough to
    // make display fast, and large enough to retain resolution in the
    // waveform.
    reduced_sampling_rate = 120,
    // Read this many frames at once when reading the file.
    read_buffer_frames = 256,

    sampling_rate = SAMPLING_RATE,
    // Each Params::ratios breakpoint is this many frames apart.
    frames_per_ratio = sampling_rate / 2,
};

// If true, print some stats about resampling times.
const static bool print_metrics = false;


PeakCache *
PeakCache::get()
{
    static PeakCache peak_cache;
    return &peak_cache;
}


double
PeakCache::pixels_per_peak(double zoom_factor)
{
    double period = reduced_sampling_rate / zoom_factor;
    if (period <= 1)
        return 1 / period;
    else
        return 1;
}


void
PeakCache::MixedEntry::add(std::shared_ptr<const Entry> entry)
{
    ASSERT(this->start == entry->start);
    if (this->peaks_n.empty()) {
        // If there's only one thing, reuse the pointer.
        if (!this->peaks1) {
            this->peaks1 = entry->peaks;
        } else {
            this->peaks_n = *peaks1;
            // These can have different sizes if one has run out of samples.
            peaks_n.resize(std::max(peaks1->size(), entry->peaks->size()));
            peaks1.reset();
            const std::vector<float> &samples = *entry->peaks;
            for (size_t i = 0; i < samples.size(); i++)
                peaks_n[i] += samples[i];
        }
    } else {
        // These can have different sizes if one has run out of samples.
        peaks_n.resize(std::max(peaks_n.size(), entry->peaks->size()));
        const std::vector<float> &samples = *entry->peaks;
        for (size_t i = 0; i < samples.size(); i++)
            peaks_n[i] += samples[i];
    }
    sources.push_back(entry);
    this->_max_peak = peaks().empty()
        ? 0 : *std::max_element(peaks().begin(), peaks().end());
}


static std::shared_ptr<const std::vector<float>>
reduce_zoom(const std::vector<float> &peaks, double zoom_factor)
{
    // zoom_factor is the number of pixels in ScoreTime(1).  So that's the
    // desired sampling rate.  E.g. zoom=2 means ScoreTime(1) is 2 pixels.
    double period = reduced_sampling_rate / zoom_factor;
    std::shared_ptr<std::vector<float>> out(new std::vector<float>());
    if (period <= 1) {
        *out = peaks;
        return out;
    }
    out->reserve(ceil(peaks.size() / period));
    double left = period;
    float accum = 0;
    ASSERT(period >= 1);
    for (float n : peaks) {
        if (left < 1) {
            out->push_back(accum);
            accum = n;
            left += period;
        }
        accum = std::max(accum, n);
        left--;
    }
    if (!peaks.empty())
        out->push_back(accum);
    return out;
}


std::shared_ptr<const std::vector<float>>
PeakCache::MixedEntry::at_zoom(double zoom_factor)
{
    if (zoom_factor != cached_zoom || !zoom_cache.get()) {
        auto start = std::chrono::steady_clock::now();
        this->zoom_cache = reduce_zoom(peaks(), zoom_factor);
        this->cached_zoom = zoom_factor;
        if (print_metrics) {
            // Zooming a track with 43 chunks takes 0.1ms.  So I think I don't
            // have to worry about zoom times.
            auto end = std::chrono::steady_clock::now();
            std::chrono::duration<double> dur = end - start;
            DEBUG("METRIC zoom " << peaks().size() << " to "
                << zoom_cache->size() << " dur: " << dur.count());
        }
    }
    return zoom_cache;
}


static double
period_at(const std::vector<double> &ratios, Wav::Frames frame)
{
    // Use frames_per_ratio to get an index into ratios, then interpolate.
    if (ratios.empty()) {
        return 1;
    }
    size_t i = floor(frame / double(frames_per_ratio));
    double frac = fmod(frame / double(frames_per_ratio), 1);
    if (i < ratios.size()-1) {
        double r1 = ratios[i], r2 = ratios[i+1];
        return (frac * (r2-r1) + r1);
    } else {
        return ratios[ratios.size()-1];
    }
}


// Originally I returned the vector directly and relied on return value
// optimization, but there was still a copy.  unique_ptr didn't believe that
// I wasn't making a copy either, so raw pointer given to Entry is it.
static std::vector<float> *
read_file(const std::string &filename, const std::vector<double> &ratios)
{
    std::vector<float> *peaks = new std::vector<float>();
    Wav *wav;
    Wav::Error err = Wav::open(filename.c_str(), &wav, 0);

    if (err) {
        // TODO should be LOG
        DEBUG("opening " << filename << ": " << err);
        return peaks;
    } else if (wav->srate() != sampling_rate) {
        DEBUG(filename << ": expected srate of " << sampling_rate << ", got "
            << wav->srate());
        return peaks;
    }

    std::vector<float> buffer(read_buffer_frames * wav->channels());
    Wav::Frames frame = 0;
    Wav::Frames frames_left = 0;
    // How many frames to consume in this period
    double srate = sampling_rate / reduced_sampling_rate;
    double period = srate * period_at(ratios, frame);
    // This could happen if someone put a 0 in ratios.
    ASSERT(period > 0);
    // DEBUG("period " << srate << " * "
    //     << period_at(ratios, frame) << " = " << period);
    unsigned int index = 0;
    float accum = 0;
    for (;;) {
        if (frames_left == 0) {
            frames_left += wav->read(buffer.data(), read_buffer_frames);
            if (!frames_left)
                break;
            index = 0;
        }
        Wav::Frames consume = floor(std::min(period, double(frames_left)));
        // TODO can I vectorize?  fabs(3) on OS X documents SIMD vvfabsf().
        for (; index < consume * wav->channels(); index++) {
            accum = std::max(accum, fabsf(buffer[index]));
        }
        frames_left -= consume;
        period -= consume;
        frame += consume;
        if (period < 1) {
            peaks->push_back(accum);
            accum = 0;
            period += srate * period_at(ratios, frame);
        }
    }
    // DEBUG("load frames: " << frame << ", peaks: " << peaks->size());
    delete wav;
    return peaks;
}


static void
write_cache(const char *filename, const std::vector<float> peaks,
    double ratios_sum)
{
    // Use 0644 because if the ratios change, I'll be overwriting this file.
    int fd = open(filename, O_WRONLY | O_CREAT, 0644);
    if (fd == -1) {
        DEBUG("can't open for writing '" << filename << "': "
            << strerror(errno));
        return;
    }
    if (write(fd, &ratios_sum, sizeof(double)) != (ssize_t) sizeof(double)
        || write(fd, peaks.data(), sizeof(float) * peaks.size())
            != (ssize_t) (sizeof(float) * peaks.size()))
    {
        DEBUG("error writing " << filename);
        unlink(filename);
    }
    close(fd);
}


static std::vector<float> *
read_cache(const char *filename, double ratios_sum)
{
    struct stat stats;
    if (stat(filename, &stats) == -1)
        return nullptr;
    int fd = open(filename, O_RDONLY);
    if (fd == -1) {
        DEBUG("can stat, but can't open '" << filename << "': "
            << strerror(errno));
        return nullptr;
    }
    double sum = 0;
    if (read(fd, &sum, sizeof(double)) == -1) {
        DEBUG("failed to read '" << filename << "' :" << strerror(errno));
    }
    // If the ratios have changed, this cache is invalid.
    if (sum != ratios_sum) {
        close(fd);
        return nullptr;
    }
    std::vector<float> *peaks =
        new std::vector<float>(stats.st_size / sizeof(float));
    if (read(fd, peaks->data(), stats.st_size) == -1) {
        DEBUG("failed to read '" << filename << "' :" << strerror(errno));
    }
    close(fd);
    return peaks;
}


static std::vector<float> *
cached_load(const std::string &filename, const std::vector<double> &ratios)
{

    std::string cache_filename = filename + ".peaks";
    double ratios_sum = 0;
    for (double d : ratios)
        ratios_sum += d;
    std::vector<float> *peaks = read_cache(cache_filename.c_str(), ratios_sum);
    if (peaks)
        return peaks;
    peaks = read_file(filename, ratios);
    write_cache(cache_filename.c_str(), *peaks, ratios_sum);
    return peaks;
}


std::shared_ptr<const PeakCache::Entry>
PeakCache::load(const Params &params)
{
    auto found = this->cache.find(params);
    std::shared_ptr<Entry> entry;
    if (found != cache.end()) {
        // DEBUG("entry exists " << params.filename
        //     << " refs: " << found->second.use_count());
        entry = found->second.lock();
    }
    if (!entry) {
        // DEBUG("load " << params.filename);

        auto start = std::chrono::steady_clock::now();
        std::vector<float> *peaks = cached_load(params.filename, params.ratios);
        entry.reset(new PeakCache::Entry(params.start, peaks));

        if (print_metrics) {
            // Loading a 3s chunk takes around 3ms.
            static double total_dur;
            static int total_count;
            auto end = std::chrono::steady_clock::now();
            std::chrono::duration<double> dur = end - start;
            total_dur += dur.count();
            total_count++;
            DEBUG("METRIC load " << params.filename << ": " << dur.count()
                << " total_dur: " << total_dur << " of " << total_count);
        }
        gc_roots.push_back(entry);
        cache[params] = entry;
    }
    return entry;
}


void
PeakCache::gc()
{
    // DEBUG("start gc");
    gc_roots.clear();
    auto it = cache.begin();
    // int del = 0, kept = 0;
    while (it != cache.end()) {
        std::shared_ptr<Entry> entry(it->second.lock());
        if (entry.get()) {
            gc_roots.push_back(entry);
            ++it;
            // kept++;
        } else {
            it = cache.erase(it);
            // del++;
        }
    }
    // DEBUG("end gc, del " << del << " kept " << kept);
}
