/* SPDX-License-Identifier: MIT
 * T720 has no anisotropic sampler state. Implement a bounded major-axis
 * footprint integral in the GPU program; maxAnisotropy is an actual runtime
 * UBO value, never silently replaced by isotropic filtering. */
#ifndef A5_MISC_ANISOTROPY_H
#define A5_MISC_ANISOTROPY_H
static nir_def *a5_sampler_word(nir_builder *b,unsigned texture,unsigned word)
{
 unsigned offset=352+32*texture+4*word;
 return nir_load_ubo(b,1,32,nir_imm_int(b,0),nir_imm_int(b,offset),
    .range_base=offset,.range=4,.align_mul=4);
}
static bool a5_lower_anisotropy(nir_builder *b,nir_tex_instr *tex,void *data)
{
 (void)data;
 if(b->shader->info.stage!=MESA_SHADER_FRAGMENT||tex->sampler_dim!=GLSL_SAMPLER_DIM_2D||
    tex->is_array||tex->is_shadow||tex->coord_components!=2||
    (tex->op!=nir_texop_tex&&tex->op!=nir_texop_txb&&tex->op!=nir_texop_txd))return false;
 int coordIndex=nir_tex_instr_src_index(tex,nir_tex_src_coord);
 if(coordIndex<0)return false;
 b->cursor=nir_before_instr(&tex->instr);
 nir_def *coord=tex->src[coordIndex].src.ssa;
 nir_def *dims=nir_vec2(b,nir_u2f32(b,a5_sampler_word(b,tex->texture_index,1)),
                         nir_u2f32(b,a5_sampler_word(b,tex->texture_index,2)));
 int ix=nir_tex_instr_src_index(tex,nir_tex_src_ddx),iy=nir_tex_instr_src_index(tex,nir_tex_src_ddy);
 nir_def *dx=ix>=0?tex->src[ix].src.ssa:nir_ddx(b,coord);
 nir_def *dy=iy>=0?tex->src[iy].src.ssa:nir_ddy(b,coord);
 nir_def *px=nir_fmul(b,dx,dims),*py=nir_fmul(b,dy,dims);
 nir_def *lx=nir_fdot2(b,px,px),*ly=nir_fdot2(b,py,py);
 nir_def *xMajor=nir_fge(b,lx,ly);
 nir_def *axis=nir_bcsel(b,xMajor,dx,dy);
 nir_def *major=nir_fsqrt(b,nir_fmax(b,lx,ly));
 nir_def *minor=nir_fsqrt(b,nir_fmin(b,lx,ly));
 nir_def *maxAniso=nir_u2f32(b,a5_sampler_word(b,tex->texture_index,3));
 nir_def *width=nir_fmax(b,nir_imm_float(b,1.0),nir_fmax(b,minor,nir_fdiv(b,major,maxAniso)));
 nir_def *count=nir_f2u32(b,nir_fclamp(b,nir_fceil(b,nir_fdiv(b,major,width)),
                                      nir_imm_float(b,1),nir_fmin(b,maxAniso,nir_imm_float(b,16))));
 count=nir_umin(b,nir_imm_int(b,16),nir_umax(b,nir_imm_int(b,1),count));
 nir_def *lod=nir_flog2(b,width);
 int bias=nir_tex_instr_src_index(tex,nir_tex_src_bias);
 if(bias>=0)lod=nir_fadd(b,lod,tex->src[bias].src.ssa);
 lod=nir_fadd(b,lod,a5_sampler_word(b,tex->texture_index,6));
 lod=nir_fclamp(b,lod,a5_sampler_word(b,tex->texture_index,4),
                        a5_sampler_word(b,tex->texture_index,5));
 const struct glsl_type *resultType=glsl_vector_type(GLSL_TYPE_FLOAT,tex->def.num_components);
 nir_variable *result=nir_local_variable_create(b->impl,resultType,"a5_aniso_result");
 nir_push_if(b,nir_fgt_imm(b,maxAniso,1));
 nir_variable *sum=nir_local_variable_create(b->impl,resultType,"a5_aniso_sum");
 nir_variable *index=nir_local_variable_create(b->impl,glsl_uint_type(),"a5_aniso_index");
 nir_store_var(b,sum,nir_imm_zero(b,tex->def.num_components,32),~0u);
 nir_store_var(b,index,nir_imm_int(b,0),1);
 nir_push_loop(b);
 nir_def *i=nir_load_var(b,index);
 nir_push_if(b,nir_uge(b,i,count));nir_jump(b,nir_jump_break);nir_pop_if(b,NULL);
 nir_def *position=nir_fadd_imm(b,nir_fdiv(b,nir_fadd_imm(b,nir_u2f32(b,i),0.5),nir_u2f32(b,count)),-0.5);
 nir_def *uv=nir_fadd(b,coord,nir_fmul(b,axis,position));
 nir_tex_instr *sample=nir_instr_as_tex(nir_instr_clone(b->shader,&tex->instr));
 nir_builder_instr_insert(b,&sample->instr);
 for(int n=(int)sample->num_srcs-1;n>=0;n--)
  if(sample->src[n].src_type==nir_tex_src_ddx||sample->src[n].src_type==nir_tex_src_ddy||
     sample->src[n].src_type==nir_tex_src_bias)nir_tex_instr_remove_src(sample,n);
 sample->op=nir_texop_txl;
 nir_src_rewrite(&sample->src[nir_tex_instr_src_index(sample,nir_tex_src_coord)].src,uv);
 nir_tex_instr_add_src(sample,nir_tex_src_lod,lod);
 nir_store_var(b,sum,nir_fadd(b,nir_load_var(b,sum),nir_f2f32(b,&sample->def)),~0u);
 nir_store_var(b,index,nir_iadd_imm(b,i,1),1);
 nir_pop_loop(b,NULL);
 nir_store_var(b,result,nir_fdiv(b,nir_load_var(b,sum),nir_u2f32(b,count)),~0u);
 nir_push_else(b,NULL);
 /* Retain original implicit/explicit-gradient semantics for anisotropy1. */
 nir_tex_instr *original=nir_instr_as_tex(nir_instr_clone(b->shader,&tex->instr));
 nir_builder_instr_insert(b,&original->instr);
 nir_store_var(b,result,nir_f2f32(b,&original->def),~0u);
 nir_pop_if(b,NULL);
 nir_def *value=nir_load_var(b,result);
 if(tex->def.bit_size==16)value=nir_f2f16(b,value);
 nir_def_rewrite_uses(&tex->def,value);
 nir_instr_remove(&tex->instr);
 return true;
}
#endif
