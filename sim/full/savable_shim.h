#pragma once
// Catch-all POD serializers for verilator-generated packed-struct members
// (FX68K s_clks/s_nanod/s_irdecod) that --savable does not handle natively.
// Non-template overloads in verilated_save.h win for all basic types; these
// templates only pick up the plain-aggregate struct types.
#include "verilated_save.h"
template <typename T>
inline VerilatedSerialize& operator<<(VerilatedSerialize& os, const T& t) {
    return os.write(&t, sizeof t);
}
template <typename T>
inline VerilatedDeserialize& operator>>(VerilatedDeserialize& os, T& t) {
    return os.read(&t, sizeof t);
}
