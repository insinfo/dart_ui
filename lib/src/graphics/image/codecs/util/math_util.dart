num fract(num x) => x - x.floorToDouble();

num mix(num x, num y, num a) => x * (1 - a) + y * a;

num sign(num x) => x < 0
    ? -1
    : x > 0
        ? 1
        : 0;

num step(num edge, num x) => x < edge ? 0 : 1;
