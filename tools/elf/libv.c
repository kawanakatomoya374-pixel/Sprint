int vf_v1(void) { return 1; }
int vf_v2(void) { return 2; }
__asm__(".symver vf_v1,vf@V1");
__asm__(".symver vf_v2,vf@@V2");
int v_user(void) { return vf_v2(); }
