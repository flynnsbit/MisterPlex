#pragma once

// Strong pixel-count units for MiSTerPlex geometry.
//
// Coded, display-cropped, and presented widths are different quantities that
// happen to be nearby integers (624 / 618 / 640 at 480p). Passing one where
// another is meant has already produced silent picture and bitrate bugs.
// These wrappers make that substitution a compile-time error: there is no
// implicit conversion between tags, and no implicit conversion to bare int.
//
// Boundary rule: raw decoder/OSD ints become a unit only at an explicit
// construction site (CodedWidth{rec.width}). That construction is the claim
// "this int is coded" — keep it next to the producer, not buried in callees.

#include <type_traits>

namespace misterplex {

template <typename Tag>
class PxCount {
public:
    using tag = Tag;

    constexpr explicit PxCount(int v = 0) noexcept : v_(v) {}

    constexpr int get() const noexcept { return v_; }

    constexpr PxCount operator+(int d) const noexcept { return PxCount(v_ + d); }
    constexpr PxCount operator-(int d) const noexcept { return PxCount(v_ - d); }
    constexpr PxCount operator*(int s) const noexcept { return PxCount(v_ * s); }
    constexpr PxCount operator/(int d) const noexcept { return PxCount(v_ / d); }
    constexpr PxCount& operator+=(int d) noexcept {
        v_ += d;
        return *this;
    }
    constexpr PxCount& operator-=(int d) noexcept {
        v_ -= d;
        return *this;
    }

    // Difference of same unit is a bare offset (e.g. crop = coded - display).
    constexpr int operator-(PxCount o) const noexcept { return v_ - o.v_; }

    constexpr bool operator==(PxCount o) const noexcept { return v_ == o.v_; }
    constexpr bool operator!=(PxCount o) const noexcept { return v_ != o.v_; }
    constexpr bool operator<(PxCount o) const noexcept { return v_ < o.v_; }
    constexpr bool operator<=(PxCount o) const noexcept { return v_ <= o.v_; }
    constexpr bool operator>(PxCount o) const noexcept { return v_ > o.v_; }
    constexpr bool operator>=(PxCount o) const noexcept { return v_ >= o.v_; }

    // Compare a typed constant to a runtime bare int (stream width, etc.).
    friend constexpr bool operator==(PxCount a, int b) noexcept { return a.v_ == b; }
    friend constexpr bool operator==(int a, PxCount b) noexcept { return a == b.v_; }
    friend constexpr bool operator!=(PxCount a, int b) noexcept { return a.v_ != b; }
    friend constexpr bool operator!=(int a, PxCount b) noexcept { return a != b.v_; }
    friend constexpr bool operator<(PxCount a, int b) noexcept { return a.v_ < b; }
    friend constexpr bool operator<(int a, PxCount b) noexcept { return a < b.v_; }
    friend constexpr bool operator<=(PxCount a, int b) noexcept { return a.v_ <= b; }
    friend constexpr bool operator<=(int a, PxCount b) noexcept { return a <= b.v_; }
    friend constexpr bool operator>(PxCount a, int b) noexcept { return a.v_ > b; }
    friend constexpr bool operator>(int a, PxCount b) noexcept { return a > b.v_; }
    friend constexpr bool operator>=(PxCount a, int b) noexcept { return a.v_ >= b; }
    friend constexpr bool operator>=(int a, PxCount b) noexcept { return a >= b.v_; }

private:
    int v_;
};

// Distinct tags — CodedWidth and PresentedWidth are unrelated types.
struct CodedWidthTag {};
struct CodedHeightTag {};
struct DisplayWidthTag {};
struct DisplayHeightTag {};
struct PresentedWidthTag {};
struct PresentedHeightTag {};

using CodedWidth = PxCount<CodedWidthTag>;
using CodedHeight = PxCount<CodedHeightTag>;
using DisplayWidth = PxCount<DisplayWidthTag>;
using DisplayHeight = PxCount<DisplayHeightTag>;
using PresentedWidth = PxCount<PresentedWidthTag>;
using PresentedHeight = PxCount<PresentedHeightTag>;

// Area helpers — cross-axis products are pixel counts, not a length unit.
constexpr int codedPixelCount(CodedWidth w, CodedHeight h) noexcept {
    return w.get() * h.get();
}
constexpr int displayPixelCount(DisplayWidth w, DisplayHeight h) noexcept {
    return w.get() * h.get();
}
constexpr int presentedPixelCount(PresentedWidth w, PresentedHeight h) noexcept {
    return w.get() * h.get();
}

// static_assert plumbing: reject accidental same-underlying-type collapse.
static_assert(!std::is_same<CodedWidth, PresentedWidth>::value,
              "CodedWidth and PresentedWidth must be distinct types");
static_assert(!std::is_same<CodedWidth, DisplayWidth>::value,
              "CodedWidth and DisplayWidth must be distinct types");
static_assert(!std::is_same<DisplayWidth, PresentedWidth>::value,
              "DisplayWidth and PresentedWidth must be distinct types");
static_assert(!std::is_convertible<PresentedWidth, CodedWidth>::value,
              "PresentedWidth must not convert to CodedWidth");
static_assert(!std::is_convertible<CodedWidth, int>::value,
              "CodedWidth must not implicitly convert to int");
static_assert(!std::is_convertible<int, CodedWidth>::value,
              "int must not implicitly convert to CodedWidth");

} // namespace misterplex
