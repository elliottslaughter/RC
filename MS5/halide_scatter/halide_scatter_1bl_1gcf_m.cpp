#include "Halide.h"
#include "halide_target_cfg.h"

#include <utility>
#include <vector>

using namespace Halide;

struct Complex {
  Expr real, imag;
  Complex(Expr r, Expr i) : real(r), imag(i) {}
  Complex operator+(const Complex &other) const {
    return{ real + other.real, imag + other.imag };
  }
  Complex operator*(const Complex &other) const {
    return{
        real * other.real - imag * other.imag
      , real * other.imag + imag * other.real
      };
  }
};

/* Not need it ATM
inline Func flushAndContinue(const char * new_name, Func & f) {
  Func ret(new_name);
  f.compute_root();
  ret(f.args()) = f(f.args());
  return ret;
}
*/

#define P(a) a(#a)
#define IP(a,b,c) a(b,c,#a)

int main(/* int argc, char **argv */) {
  int
      over = 8
    , grid_size = 2048
    ;

  Param<double>
      P(scale)
    , P(wstep)
    ;
  Param<int>
      P(gcf_layer_size)
    , P(ts_ch)
    ;
  ImageParam IP(uvwf, type_of<double>(), 2);
  ImageParam IP(vis, type_of<double>(), 2);
  ImageParam IP(gcf, type_of<double>(), 2);

  Func
      P(uvs)
    , P(uv)
    , P(overc)
    , P(gcfoff)
    ;

  Var P(t)
    , P(uvdim)
    , P(bl)
    ;
  const Expr
      _U = 0
    , _V = 1
    ;
  
  uvs(uvdim, t) = uvwf(uvdim, t) * scale;
  overc(uvdim, t) = clamp(cast<int>(round(over * (uvs(uvdim, t) - floor(uvs(uvdim, t))))), 0, 7);
  uv(uvdim, t) = cast<int>(round(uvs(uvdim, t)) + grid_size / 2 - gcf_layer_size / 2);
  gcfoff(t) = (overc(0, t) * over + overc(1, t)) * gcf_layer_size * gcf_layer_size;
  
  overc.bound(uvdim, 0, 2);
  uv.bound(uvdim, 0, 2);

  overc.bound(t, 0, ts_ch);
  uv.bound(t, 0, ts_ch);
  gcfoff.bound(t, 0, ts_ch);

  overc.compute_root();
  uv.compute_root();
  gcfoff.compute_root();

  RDom red(
      0, gcf_layer_size
    , 0, ts_ch
    , 0, gcf_layer_size
    );
  RVar
      rgcfx = red.x
    , rvis  = red.y
    , rgcfy = red.z
    ;

  const Expr
      _REAL = 0
    , _IMAG = 1
    ;

  Expr gcf_pix_off = gcfoff(rvis) + rgcfx + rgcfy * gcf_layer_size; 
  Complex gcfC(
      gcf(0, gcf_pix_off)
    , gcf(1, gcf_pix_off)
    );

  Complex visC(
      vis(_REAL, rvis)
    , vis(_IMAG, rvis)
    );

  Func P(uvg);
  Var P(cmplx)
    , P(x)
    , P(y)
    ;
  uvg(cmplx, x, y) = cast<double>(0.0f);

  Expr
      clampedU = clamp(uv(_U, rvis) + rgcfx, 0, grid_size - 1)
    , clampedV = clamp(uv(_V, rvis) + rgcfy, 0, grid_size - 1)
    ;

  uvg(
      _REAL
    , clampedU
    , clampedV
    ) += (visC * gcfC).real
    ;
  uvg(
      _IMAG
    , clampedU
    , clampedV
    ) += (visC * gcfC).imag
    ;

  uvg.bound(cmplx, 0, 2);
  uvg.bound(x, 0, grid_size);
  uvg.bound(y, 0, grid_size);
  Var P(xc);
  uvg.fuse(x, cmplx, xc).vectorize(xc, 4);

  // Var x_outer, y_outer, x_inner, y_inner;
  // uvg.tile(x, y, x_outer, y_outer, x_inner, y_inner, 4, 4);

  std::vector<Halide::Argument> compile_args = {
      scale
    , wstep
    , ts_ch
    , uvwf
    , vis
    , gcf_layer_size
    , gcf
  };
  uvg.compile_to_lowered_stmt("uvg11.html", compile_args, HTML);

  Target target(
      Target::__HALIDE_HOST
    , Target::X86, 64
    , { Target::SSE41
    	__HALIDE_ADD_AVX__
      }
    );
  uvg.compile_to_file("uvg11_full", compile_args, target);
}
