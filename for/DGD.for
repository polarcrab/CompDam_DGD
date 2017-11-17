Module DGD_Mod
  ! Module for all DGD calculations

Contains


  Subroutine DGDInit(U,F,m,p,sv,ndir,nshr,DT,Cauchy,enerIntern)
    ! Checks for the initiation of matrix damage, represented as a DGD
    ! cohesive crack. If the crack orientation is a priori unknown, it
    ! will be determined in this subroutine.

    Use forlog_Mod
    Use matrixAlgUtil_Mod
    Use matProp_Mod
    Use stateVar_Mod
    Use parameters_Mod
    Use stress_Mod
    Use cohesive_mod
    Use strain_mod
    Use CDM_fiber_mod
    Use schapery_mod

    Include 'vaba_param.inc'

    ! -------------------------------------------------------------------- !
    ! Arguments
    Type(matProps), intent(IN) :: m
    Type(parameters), intent(IN) :: p
    Type(stateVars), intent(INOUT) :: sv
    Double Precision, intent(IN) :: F(3,3), U(3,3)                         ! Deformation gradient stretch tensor
    Integer, intent(IN) :: ndir
    Integer, intent(IN) :: nshr
    Double Precision, intent(IN) :: DT
    Double Precision, intent(OUT) :: Cauchy(ndir,ndir)                     ! Cauchy stress
    Double Precision, intent(OUT) :: enerIntern                            ! Internal energy

    ! -------------------------------------------------------------------- !
    ! Locals

    Double Precision :: Stiff(ndir+nshr,ndir+nshr)                         ! Stiffness
    Double Precision :: eps(ndir,ndir)                                     ! Strain
    Double Precision :: stress(ndir,ndir)                                  ! Stress
    Double Precision :: F_inverse_transpose(3,3)                           ! Inverse transpose of the Deformation Gradient Tensor
    Double Precision :: X(3,3)                                             ! Reference configuration

    ! Cohesive surface
    Double Precision :: normal(3)                                          ! Normal vector (to cohesive surface)
    Double Precision :: R_cr(3,3)                                          ! Basis coordinate system for the cohesive surface
    Double Precision :: Pen(3)                                             ! Penalty stiffnesses
    Double Precision :: T(3)                                               ! Tractions on the cohesive surface
    Double Precision :: delta(3)                                           ! Current displacement jumps in crack coordinate system
    Double Precision :: B_temp, beta                                       ! Placeholder (temp.) variables for Mode-mixity
    Double Precision :: FIm_temp

    ! Matrix crack cohesive surface normal
    Double Precision :: alpha_temp                                         ! Current alpha (used in loop through possible alphas)
    Integer :: alpha_test, alphaQ                                          ! Alpha = normal to matrix crack cohesive surface
    Integer :: Q                                                           ! Flag: Q=2 for matrix crack; Q=3 for delamination
    Integer :: A, A_min, A_max                                             ! Range through which the code searches for alpha
    Integer :: alpha0_deg_2                                                ! negative symmetric alpha0 with normal in positive direction

    ! Fiber
    Double Precision :: FIfC                                               ! Fiber compression damage threshold
    Double Precision :: d1
    Double Precision :: normalDir(3)                                       ! Normal to the crack plane in the reference configuration
    Double Precision :: fiberDir(3)                                        ! Current fiber direction
    Double Precision :: pk2_fiberDir(3,3)                                  ! 2PK stress in the fiber direction
    Double Precision :: R_phi0(3,3)                                        ! Rotation to the misaligned frame
    Double Precision :: gamma_rphi0                                        ! Shear strain in the misaligned frame
    Double Precision :: E1                                                 ! Fiber direction modulus; used for fiber nonlinearity

    ! Miscellaneous
    Double Precision :: rad_to_deg, deg_to_rad
    Double Precision, parameter :: zero=0.d0, one=1.d0, two=2.d0
    Double Precision, parameter :: pert=0.0001d0                           ! Small perturbation used to compute a numerical derivative

    ! -------------------------------------------------------------------- !

    ! Miscellaneous constants
    rad_to_deg = 45.d0/ATAN(one)  ! Converts radians to degrees when multiplied
    deg_to_rad = one/rad_to_deg   ! Converts degrees to radians when multiplied

    ! Initialize outputs
    d1       = zero
    sv%d2    = zero
    sv%FIm   = zero
    sv%B     = zero
    sv%Fb1   = zero
    sv%Fb2   = zero
    sv%Fb3   = zero
    pk2_fiberDir = zero

    ! Reference configuration
    X = zero; X(1,1) = sv%Lc(1); X(2,2) = sv%Lc(2); X(3,3) = sv%Lc(3)
    F_inverse_transpose = MInverse(TRANSPOSE(F))

    ! Compute the strains: eps, Plas12, Inel12
    ! Note the first argument is a flag to define the strain to use
    Call Strains(F, m, U, DT, ndir, eps, sv%Plas12, sv%Inel12, sv%d_eps12, sv%status, p%gamma_max, E1)

    ! Calculate the current Schapery micro-damage state variable as a function of the current strain state
    sv%Sr = Schapery_damage(m, eps, sv%Sr)

    ! Check fiber tension or fiber compression damage
    If (eps(1,1) .GE. zero) Then    ! Fiber tension

      ! Set rfC for failure index output
      If (sv%rfC .EQ. one) Then
        sv%rfC = zero
      End If

      ! Evaluate fiber tension failure criteria and damage variable
      If (m%fiberTenDam) Then
        Call FiberTenDmg(eps, ndir, E1, m%XT, m%GXT, m%fXT, m%fGXT, sv%Lc(1), sv%rfT, sv%d1T, sv%d1C, sv%STATUS)
        Call log%debug('Computed fiber damage variable, d1T ' // trim(str(sv%d1T)))

        d1 = sv%d1T
      End If

      ! Build the stiffness matrix
      Stiff = StiffFunc(ndir+nshr, E1, m%E2*Schapery_reduction(sv%Sr, m%es), m%E3, m%G12*Schapery_reduction(sv%Sr, m%gs), m%G13, m%G23, m%v12, m%v13, m%v23, d1, zero, zero)

      ! Calculate stress
      stress = Hooke(Stiff, eps, nshr)
      Cauchy = convertToCauchy(stress, m%strainDef, F, U)

    Else  ! Compression in 1-dir

      ! Set rfT for failure index output
      If (sv%rfT .EQ. one) Then
        sv%rfT = zero
      End If

      ! Check for fiber compression damage initiation
      If (m%fiberCompDamFKT) Then

        ! -------------------------------------------------------------------- !
        !    Compute stress in the material (considering phi0)                 !
        ! -------------------------------------------------------------------- !

        ! Rotation from reference frame to fiber misaligned frame
        fiberDir = (/cos(sv%phi0), sin(sv%phi0), zero/)
        normalDir = (/-sin(sv%phi0), cos(sv%phi0), zero/)
        R_phi0(:,1) = fiberDir
        R_phi0(:,2) = normalDir
        R_phi0(:,3) = (/zero, zero, one/)

        ! Calculate strain in the fiber-aligned frame
        Call Strains(F, m, U, DT, ndir, eps, sv%Plas12, sv%Inel12, sv%d_eps12, sv%STATUS, p%gamma_max, E1, R_phi0)

        ! Get total 1,2 strain component
        gamma_rphi0 = two*(eps(1,2) + sv%Plas12/two)

        ! Only decompose element if the plastic strain is nonnegligible and the kinkband is smaller than the element size
        If (sv%Inel12 .GT. 0.00001d0) Then
          If (m%w_kb/sv%Lc(1) .LT. p%kb_decompose_thres) Then
            Call log%debug('DGDInit triggering DGDKinkband.')
            sv%d1C   = 1.d-6    ! Used as a flag to call DGDEvolve
            sv%alpha = zero     ! Assume an in-plane kinkband
            sv%Fb1 = F(1,1)
            sv%Fb2 = F(2,1)
            sv%Fb3 = F(3,1)
          End If
        End If

        ! Compute the undamaged stiffness matrix
        Stiff = StiffFunc(ndir+nshr, E1, m%E2*Schapery_reduction(sv%Sr, m%es), m%E3, m%G12*Schapery_reduction(sv%Sr, m%gs), m%G13, m%G23, m%v12, m%v13, m%v23, zero, zero, zero)

        ! Calculate stress
        pk2_fiberDir = Hooke(Stiff, eps, nshr)  ! 2PK in the fiber direction
        stress = MATMUL(R_phi0, MATMUL(pk2_fiberDir, TRANSPOSE(R_phi0)))  ! 2PK rotated back to the reference direction
        Cauchy = convertToCauchy(stress, m%strainDef, F, U)  ! Cauchy stress in the reference frame

        ! Failure index for fiber kinking
        sv%rfC = abs((-1*Cauchy(1,1)*cos(two*(sv%phi0+gamma_rphi0)))/((ramberg_osgood(gamma_rphi0 + pert, m%G12, m%aPL, m%nPL) - ramberg_osgood(gamma_rphi0 - pert, m%G12, m%aPL, m%nPL)) / (two * pert)))

        ! Rotation to the crack frame / fiber-aligned frame
        R_cr(:,1) = Norm(MATMUL(F, fiberDir))
        R_cr(:,2) = Norm(MATMUL(F_inverse_transpose, normalDir))
        R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

        ! Calculate the angle that define the rotation of the fibers
        sv%gamma = ATAN(R_cr(2,1)/R_cr(1,1)) - sv%phi0

        d1 = zero

      Else

        If (m%fiberCompDamBL) Then
          Call FiberCompDmg(eps, ndir, E1, m%XC, m%GXC, m%fXC, m%fGXC, sv%Lc(1), sv%rfT, sv%rfC, sv%d1T, sv%d1C, sv%STATUS)
          Call log%debug('Computed fiber damage variable, d1C ' // trim(str(sv%d1C)))

          d1 = sv%d1C
        End If

        ! Build the stiffness matrix
        Stiff = StiffFunc(ndir+nshr, E1, m%E2*Schapery_reduction(sv%Sr, m%es), m%E3, m%G12*Schapery_reduction(sv%Sr, m%gs), m%G13, m%G23, m%v12, m%v13, m%v23, d1, zero, zero)

        ! Calculate stress
        stress = Hooke(Stiff, eps, nshr)
        Cauchy = convertToCauchy(stress, m%strainDef, F, U)

      End If

    End If

    ! -------------------------------------------------------------------- !
    !    Search for matrix crack initiation only when no fiber damage has occured
    ! -------------------------------------------------------------------- !
    If (m%matrixDam .AND. sv%d1T .EQ. zero .AND. sv%d1C .EQ. zero) Then
      ! Get fiber direction
      R_cr(:,1) = Norm(F(:,1)) ! fiber direction
      normal(1) = zero

      ! alphaQ is the angle between intralaminar and interlaminar oriented cracks
      alphaQ = FLOOR(ATAN(sv%Lc(2)/sv%Lc(3))*rad_to_deg)
      alphaQ = alphaQ - MOD(alphaQ, p%alpha_inc)

      ! Search through range of alphas to find the correct one (alpha=-999 is a flag to run this search)
      If (sv%alpha .EQ. -999) Then
        A_min = -alphaQ
        A_max = -alphaQ + 170

        If (-m%alpha0_deg .LT. A_min) Then
          alpha0_deg_2 = 180 - m%alpha0_deg
        Else
          alpha0_deg_2 = -m%alpha0_deg
        End If

      ! Alpha was specified in the initial conditions, use the specified angle
      Else
        ! TODO - check that alpha is a valid angle.
        A_min = sv%alpha
        A_max = sv%alpha
      End If

      ! -------------------------------------------------------------------- !
      !    Loop through possible alphas, save the angle where the FC is max  !
      ! -------------------------------------------------------------------- !
      A = A_min
      CrackAngle: Do  ! Test various alphas

        alpha_temp = A*deg_to_rad  ! crack angle being evaluated (converted to radians)

        ! Crack normal in the reference configuration
        normal(2) = COS(alpha_temp)
        normal(3) = SIN(alpha_temp)

        ! Current crack normal direction
        R_cr(:,2) = Norm(MATMUL(F_inverse_transpose, normal))

        ! Current transverse direction
        R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

        ! -------------------------------------------------------------------- !
        !    Determine the cohesive penalty stiffnesses                        !
        ! -------------------------------------------------------------------- !
        ! Does this DGD crack represent a crack or a delamination?
        If (A .EQ. 90) Then
          Q = 3
        Else
          Q = 2
        End If
        Pen(2) = p%penStiffMult*m%E2/sv%Lc(Q)
        Pen(1) = Pen(2)*m%GYT*m%SL*m%SL/(m%GSL*m%YT*m%YT) ! Corresponds to Turon et al (2010)
        Pen(3) = Pen(2)*m%GYT*m%ST*m%ST/(m%GSL*m%YT*m%YT)

        ! -------------------------------------------------------------------- !
        !    Determine the cohesive displacement-jump                          !
        ! -------------------------------------------------------------------- !
        T = MATMUL(Cauchy, R_cr(:,2)) ! Traction on fracture surface

        delta = MATMUL(TRANSPOSE(R_cr), T) / Pen

        ! -------------------------------------------------------------------- !
        !    Evaluate the cohesive law initiation criterion                    !
        ! -------------------------------------------------------------------- !
        Call cohesive_damage(m, delta, Pen, delta(2), B_temp, FIm_temp)

        ! -------------------------------------------------------------------- !
        !    Save the values corresponding to the maximum failure criteria     !
        ! -------------------------------------------------------------------- !
        If (FIm_temp .GT. sv%FIm) Then
          sv%FIm        = FIm_temp
          sv%B          = B_temp
          alpha_test    = A
          sv%Fb1        = F(1,Q)
          sv%Fb2        = F(2,Q)
          sv%Fb3        = F(3,Q)
        End If

        If (A .EQ. A_max) EXIT CrackAngle

        ! Advance the crack angle
        NextAngle: Do
          ! Check to see if incrementing alpha would pass over +alpha0
          If (A .LT. m%alpha0_deg .AND. A + p%alpha_inc .GT. m%alpha0_deg) Then
            A = m%alpha0_deg
          ! If already at +alpha0, increment to next nearest multiple of alpha_inc
          Else If (A .EQ. m%alpha0_deg) Then
            A = A + p%alpha_inc - MOD(A + p%alpha_inc, p%alpha_inc)
          ! Check to see if incrementing alpha would pass over -alpha0
          Else If (A .LT. alpha0_deg_2 .AND. A + p%alpha_inc .GT. alpha0_deg_2) Then
            A = alpha0_deg_2
          ! If already at -alpha0, increment to next nearest multiple of alpha_inc
          Else If (A .EQ. alpha0_deg_2) Then
            A = A + p%alpha_inc - MOD(A + p%alpha_inc, p%alpha_inc)
          Else
            A = A + p%alpha_inc
          End If

          If (A .NE. 90) Exit NextAngle  ! Only evaluate 90 if is set via initial condition
        End Do NextAngle

      End Do CrackAngle

      ! -------------------------------------------------------------------- !
      !    If failure occurs, save alpha and indicate small dmg              !
      ! -------------------------------------------------------------------- !
      If (sv%FIm .GE. one) Then
        sv%d2    = 1.d-8 ! Used as a flag to call DGDEvolve
        sv%alpha = alpha_test
        Call log%info('DGDInit found FIm > one. Matrix damage initiated.')
      End If
    End If

    ! -------------------------------------------------------------------- !
    !    Update elastic energy variable.                                   !
    ! -------------------------------------------------------------------- !
    enerIntern = zero
    Do I=1,3
      Do J=1,3
        enerIntern = enerIntern + 0.5d0*stress(I,J)*eps(I,J)
      End Do
    End Do

    Return
  End Subroutine DGDInit


  Subroutine DGDEvolve(U,F,F_old,m,p,sv,ndir,nshr,DT,Cauchy,enerIntern)
    ! Determines the matrix damage state variable based on the current   !
    ! deformation and mode mixity.                                       !

    Use forlog_Mod
    Use matrixAlgUtil_Mod
    Use matProp_Mod
    Use stateVar_Mod
    Use parameters_Mod
    Use stress_Mod
    Use cohesive_mod
    Use strain_mod
    Use CDM_fiber_mod
    Use friction_mod
    Use schapery_mod

    Include 'vaba_param.inc'

    ! -------------------------------------------------------------------- !
    ! Arguments
    Type(matProps), intent(IN) :: m
    Type(parameters), intent(IN) :: p
    Type(stateVars), intent(INOUT) :: sv
    Double Precision, Intent(IN) :: F(3,3), U(3,3), F_old(3,3)               ! Deformation gradient, stretch tensor
    Double Precision, Intent(IN) :: DT                                       ! Delta temperature
    Integer, intent(IN) :: ndir, nshr
    Double Precision, Intent(OUT) :: Cauchy(ndir,ndir)
    Double Precision, Intent(OUT) :: enerIntern

    ! -------------------------------------------------------------------- !
    ! Locals
    Integer :: mode                                                          ! Flag for whether the crack is a standard matrix crack (0) or a fiber compression matrix crack (1)

    Double Precision :: Stiff(ndir+nshr,ndir+nshr)                           ! Stiffness
    Double Precision :: stress(ndir,ndir)                                    ! Stress (energy conjugate to strain definition)
    Double Precision :: eps(ndir,ndir)                                       ! Strain

    ! Cohesive surface
    Double Precision :: alpha_rad                                            ! alpha in radians
    Double Precision :: R_cr(3,3)                                            ! Basis coordinate system for the cohesive surface
    Double Precision :: T(3), T_bulk(3)                                      ! Traction on crack interface from bulk material stresses
    Double Precision :: T_coh(3)                                             ! Traction on crack interface from cohesive law
    Double Precision :: normal(3)                                            ! Normal to the crack plane in the reference configuration
    Double Precision :: delta_coh(ndir,ndir)                                 ! matrix of cohesive displacements
    Double Precision :: damage_max                                           ! Maximum value for damage variable
    Double Precision :: Pen(3)                                               ! Penalty stiffnesses
    Double Precision :: damage_old, AdAe
    Double Precision :: delta_n_init
    Integer :: Q, alphaQ                                                     ! Flag to specify matrix crack or delamination (Q=2 matrix crack, Q=3 delam); angle at which transition occurs (depends on element geometry)
    Integer :: MD, EQk                                                       ! MatrixDamage and equilibrium loop indices

    ! Equilibrium loop
    Double Precision :: F_bulk(3,3), U_bulk(3,3)
    Double Precision :: F_bulk_old(3), F_bulk_change(3), F_bulk_inverse(3,3)
    Double Precision :: Residual(3)                                          ! Residual stress vector
    Double Precision :: tol_DGD
    Double Precision :: err, err_old

    ! For jacobian
    Double Precision :: Cauchy_d(ndir,ndir,3)                                ! Derivative of the Cauchy stress tensor
    Double Precision :: stress_d(ndir,ndir,3)                                ! Derivative of the stress
    Double Precision :: eps_d(ndir,ndir,3)                                   ! Derivative of the strain
    Double Precision :: delta_coh_d(3,3,3), R_cr_d(3,3,3), F_bulk_d(3,3,3)
    Double Precision :: T_coh_d(3,3), T_d(3,3)
    Double Precision :: r1length, r2length                                   ! Magnitude used for computing derivative
    Double Precision :: Jac(3,3)                                             ! Jacobian
    Double Precision :: T_coh_d_den_temp

    ! Convergence tools
    Double Precision :: crack_inflection_aid, aid, crack_inflection_cutback
    Integer :: restarts, cutbacks, restarts_max
    Integer :: crack_inversions, crack_inversions_max
    Logical :: crack_inverted
    Logical :: crack_open, crack_was_open, crack_open_test
    Logical :: Restart, Cutback

    ! Misc
    Double Precision :: X(ndir,ndir)                                         ! Reference configuration
    Double Precision :: dGdGc
    Double Precision :: Plas12_temp, Inel12_temp, eps12_temp, Sr_temp
    Double Precision :: tr, Y(ndir,ndir)
    Double Precision :: eye(ndir,ndir)
    Double Precision :: Fb_s1(3), Fb_s3(3)
    Double Precision :: L

    ! Added by Drew for fiber compression
    !Double Precision, Intent(IN) :: XC,w_kb,phi_ff
    Double Precision :: fiberDir(3)                                          ! Misligned fiber direction in the reference configuration
    Double Precision :: rfT_temp, rfC_temp                                   ! Fiber damage thresholds, from previous converged solution
    Double Precision :: d1T_temp, d1C_temp                                   ! Fiber damage variables, from previous converged solution
    Double Precision :: phi0
    Double Precision :: d1

    Double Precision :: E1

    ! Friction
    Double Precision :: slide_old(2)
    Integer :: forced_sticking
    Logical :: Sliding

    Double Precision, parameter :: zero=0.d0, one=1.d0, two=2.d0

    ! -------------------------------------------------------------------- !
    Call log%debug('Start of DGDEvolve')

    damage_max = one ! Maximum value for damage variables

    restarts_max = 2  ! equal to the number of starting points minus 1
    crack_inflection_cutback = 0.99d0
    crack_inversions_max = 4

    ! Initialize outputs
    sv%FIm = zero

    X = zero; X(1,1) = sv%Lc(1); X(2,2) = sv%Lc(2); X(3,3) = sv%Lc(3) ! Ref. Config.

    eye = zero; Do I = 1,3; eye(I,I) = one; End Do ! Identity Matrix

    tol_DGD = m%YT*p%tol_DGD_f ! Equilibrium loop tolerance [stress]

    ! crack or delamination?
    alphaQ = FLOOR(ATAN(sv%Lc(2)/sv%Lc(3))*45.d0/ATAN(one))
    alphaQ = alphaQ - MOD(alphaQ, p%alpha_inc)
    If (sv%alpha .NE. 90) Then
      Q = 2 ! matrix crack
    Else
      Q = 3 ! delamination
    End If
    alpha_rad = sv%alpha/45.d0*ATAN(one) ! alpha [radians]

    ! -------------------------------------------------------------------- !
    ! Penalty stiffness
    Pen(2) = p%penStiffMult*m%E2/sv%Lc(Q)
    Pen(1) = Pen(2)*m%GYT*m%SL*m%SL/(m%GSL*m%YT*m%YT) ! Corresponds to Turon et al (2010)
    Pen(3) = Pen(2)*m%GYT*m%ST*m%ST/(m%GSL*m%YT*m%YT)

    ! -------------------------------------------------------------------- !
    !    Define a crack-based coordinate system with a basis R_cr(3,3):    !
    ! -------------------------------------------------------------------- !
    normal(1) = zero
    normal(2) = COS(alpha_rad)
    normal(3) = SIN(alpha_rad)

    ! Current fiber direction
    R_cr(:,1) = Norm(F(:,1))

    ! -------------------------------------------------------------------- !
    !    Initial guesses for F_bulk:                                       !
    ! -------------------------------------------------------------------- !
    F_bulk(:,:) = F(:,:)
    F_bulk(1,Q) = sv%Fb1
    F_bulk(2,Q) = sv%Fb2
    F_bulk(3,Q) = sv%Fb3

    If (Length(F_bulk(:,Q)) .EQ. zero) F_bulk(Q,Q) = one

    ! Initialize the displ across the cohesive interface as zero
    delta_coh = zero

    ! -------------------------------------------------------------------- !
    !    Definition of Equilibrium alternate starting points:              !
    ! -------------------------------------------------------------------- !
    ! Starting point 1 is the Q-th column of the previous solution for F_bulk
    ! Starting point 2 is the Q-th column of F
    ! Starting point 3 is the cross product of the two non-decomposed columns of F
    Fb_s3(:) = Norm(CrossProduct(F(:,MOD(Q,3)+1), F(:,Q-1)))

    ! -------------------------------------------------------------------- !
    !    MatrixDamage Loop and solution controls definition                !
    ! -------------------------------------------------------------------- !
    MD = 0 ! Counter for MatrixDamage loop

    MatrixDamage: Do
      MD = MD + 1
      Call log%debug('MD', MD)
      Fb_s1(:) = F_bulk(:,Q) ! Starting point 1
      slide_old(:) = sv%slide(:)

      AdAe = sv%d2/(sv%d2 + (one - sv%d2)*two*Pen(1)*m%GSL/(m%SL*m%SL))

      ! -------------------------------------------------------------------- !
      !    Equilibrium Loop and solution controls definition                 !
      ! -------------------------------------------------------------------- !
      Restart = .False.
      Cutback = .False.
      restarts = 0  ! Indicates the number of loop restarts with new starting points
      cutbacks = 0  ! Cut-back counter
      crack_inversions = 0
      crack_inverted = .False.

      forced_sticking = 0  ! Indicates that sliding has not been suppressed
      aid = one  ! Artificially reduces the rate of change in F_bulk
      crack_inflection_aid = one
      err = Huge(zero)
      EQk = 0

      Equilibrium: Do ! Loop to determine the current F_bulk
        EQk = EQk + 1
        Call log%debug('EQk', EQk)

        ! -------------------------------------------------------------------- !
        If (Restart) Then

          ! Reset the Restart and Cutback flags
          Restart = .False.
          Cutback = .False.

          ! Attempt to use the "no sliding" condition, if not converged conventionally with friction.
          If (forced_sticking .EQ. 0 .AND. m%friction) Then
            Call log%info('Attempting no sliding, MD: ' // trim(str(MD)) // ' Restart: ' // trim(str(restarts)))
            forced_sticking = 1
          Else
            ! Advance the restart counter
            restarts = restarts + 1
            Call log%info('Restarting Equilibrium loop with new start point, Restart: ' // trim(str(restarts)))
            forced_sticking = 0
          End If

          ! If all starting points have been fully used...
          If (restarts .GT. restarts_max) Then
            ! ...and if the matrix damage is already fully developed, delete the element.
            If (sv%d2 .GE. damage_max) Then
              If (sv%alpha .EQ. -999) Then
                Call writeDGDArgsToFile(m,p,sv,U,F,F_old,ndir,nshr,DT)
                Call log%error('Invalid alpha. Check value for alpha in the initial conditions.')
              End If
              Call log%warn('Deleting failed element for which no solution could be found.')
              sv%STATUS = 0
              Exit MatrixDamage
            End If
            ! ...raise an error and halt the subroutine.
            Call writeDGDArgsToFile(m,p,sv,U,F,F_old,ndir,nshr,DT)
            Call log%error('No starting points produced a valid solution.')
          End If

          cutbacks = 0
          crack_inversions = 0
          crack_inverted = .False.

          ! Restart from a starting point
          F_bulk = F
          If (restarts .EQ. 0) Then
            F_bulk(:,Q) = Fb_s1(:)  ! Use starting point 1
          Else If (restarts .EQ. 1) Then
            Continue                ! Use starting point 2
          Else If (restarts .EQ. 2) Then
            F_bulk(:,Q) = Fb_s3(:)  ! Use starting point 3
          End If

          aid = one
          crack_inflection_aid = one

          ! Reset err
          err = Huge(zero)
        ! -------------------------------------------------------------------- !
        Else If (Cutback) Then

          ! Reset the Cutback flag
          Cutback = .False.

          ! Advance the cutback counter
          cutbacks = cutbacks + 1
          Call log%info('Cutting back, Cutbacks: ' // trim(str(cutbacks)) //', Restart: ' // trim(str(restarts)))

          aid = p%cutback_amount**cutbacks

          F_bulk(:,Q) = F_bulk_old(:) - F_bulk_change(:)*aid*crack_inflection_aid

          ! Reset err to the last converged value
          err = err_old
        End If
        ! -------------------------------------------------------------------- !
        ! Initialize all temporary state variables for use in Equilibrium loop:

        ! Shear nonlinearity variables
        Plas12_temp = sv%Plas12
        Inel12_temp = sv%Inel12

        ! CDM fiber damage variables
        d1 = zero
        d1T_temp = sv%d1T
        d1C_temp = sv%d1C
        rfT_temp = sv%rfT
        rfC_temp = sv%rfC

        ! Store re-used matrices
        F_bulk_inverse = MInverse(F_bulk)

        R_cr(:,2) = MATMUL(TRANSPOSE(F_bulk_inverse), normal)
        r2length = Length(R_cr(:,2))    ! Un-normalized length of R_cr(:,2), used in the Jacobian
        R_cr(:,2) = R_cr(:,2)/r2length  ! Normalized R_cr(:,2)
        R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

        delta_coh(:,Q) = MATMUL(TRANSPOSE(R_cr), F(:,Q) - F_bulk(:,Q))*X(Q,Q)

        If (delta_coh(2,Q) .GE. zero) Then
          crack_open = .True.
        Else
          crack_open = .False.
        End If

        ! TODO for other strain component implementation: Calculate U_bulk from F_bulk
        U_bulk = zero

        ! Calculate the sign of the change in shear strain (for shear nonlinearity subroutine)
        If (m%shearNonlinearity .AND. Q .EQ. 2) Then
           eps12_temp = Sign(one, (F(1,1)*F_bulk(1,2) + F(2,1)*F_bulk(2,2) + F_bulk(3,2)*F(3,1)) - (F_old(1,1)*sv%Fb1 + F_old(2,1)*sv%Fb2 + sv%Fb3*F_old(3,1)))
        Else
           eps12_temp = sv%d_eps12
        End If

        ! Compute the strains: eps, Plas12, Inel12
        ! Note the first argument is a flag to define the strain to use
        Call Strains(F_bulk, m, U_bulk, DT, ndir, eps, Plas12_temp, Inel12_temp, eps12_temp, sv%STATUS, p%gamma_max, E1)

        ! Calculate the current Schapery micro-damage state variable as a function of the current strain state
        Sr_temp = Schapery_damage(m, eps, sv%Sr)

        ! -------------------------------------------------------------------- !
        !    Evaluate the CDM fiber failure criteria and damage variable:      !
        ! -------------------------------------------------------------------- !
        If (eps(1,1) .GE. zero) Then
          If (m%fiberTenDam) Call FiberTenDmg(eps, ndir, E1, m%XT, m%GXT, m%fXT, m%fGXT, sv%Lc(1), rfT_temp, d1T_temp, d1C_temp, sv%STATUS)
          d1 = d1T_temp
          d1C_temp = sv%d1C
        Else If (m%fiberCompDamBL) Then
          Call FiberCompDmg(eps, ndir, E1, m%XC, m%GXC, m%fXC, m%fGXC, sv%Lc(1), rfT_temp, rfC_temp, d1T_temp, d1C_temp, sv%STATUS)
          d1 = d1C_temp
        End If

        ! -------------------------------------------------------------------- !
        !    Build the stiffness matrix:                                       !
        ! -------------------------------------------------------------------- !
        Stiff = StiffFunc(ndir+nshr, E1, m%E2*Schapery_reduction(Sr_temp, m%es), m%E3, m%G12*Schapery_reduction(Sr_temp, m%gs), m%G13, m%G23, m%v12, m%v13, m%v23, d1, zero, zero)

        ! -------------------------------------------------------------------- !
        !    Determine the bulk material tractions on the fracture plane:      !
        ! -------------------------------------------------------------------- !
        stress = Hooke(Stiff, eps, nshr)
        Cauchy = convertToCauchy(stress, m%strainDef, F_bulk, U_bulk)
        T = MATMUL(Cauchy, R_cr(:,2))  ! Traction on fracture surface
        T_bulk = MATMUL(TRANSPOSE(R_cr), T)

        ! -------------------------------------------------------------------- !
        !    Determine the cohesive tractions:                                 !
        ! -------------------------------------------------------------------- !
        If (crack_open) Then  ! Open cracks

          T_coh(:) = Pen(:)*(one - sv%d2)*delta_coh(:,Q)

          sv%slide(1) = delta_coh(1,Q)
          sv%slide(2) = delta_coh(3,Q)

        Else  ! Closed cracks

          If (.NOT. m%friction) Then  ! Closed cracks without friction
            T_coh(1) = Pen(1)*(one - sv%d2)*delta_coh(1,Q)
            T_coh(2) = Pen(2)*delta_coh(2,Q)
            T_coh(3) = Pen(3)*(one - sv%d2)*delta_coh(3,Q)

            sv%slide(1) = delta_coh(1,Q)
            sv%slide(2) = delta_coh(3,Q)

          Else  ! Closed cracks with friction
            Sliding = crack_is_sliding(delta_coh(:,Q), Pen, slide_old, m%mu, m%mu)
            If (forced_sticking .EQ. 1) Sliding = .False.
            Call crack_traction_and_slip(delta_coh(:,Q), Pen, slide_old, sv%slide, m%mu, m%mu, sv%d2, AdAe, T_coh, Sliding)

          End If

        End If

        ! -------------------------------------------------------------------- !
        !    Define the stress residual vector, R. R is equal to the           !
        !    difference in stress between the cohesive interface and the bulk  !
        !    stress projected onto the cohesive interface                      !
        ! -------------------------------------------------------------------- !
        Residual = T_coh - T_bulk

        ! Error in terms of the stress residual on the crack surface
        err_old = err
        err = Length(Residual)

        ! Output for visualizations
        Call log%debug('err', err)
        Call log%debug('Fb', F_bulk)

        ! -------------------------------------------------------------------- !
        !    Check for convergence.                                            !
        ! -------------------------------------------------------------------- !

        ! Check for a diverging solution
        If (err .GE. err_old) Then

          If (crack_inverted) Then
            ! A cut-back will not be performed if the crack opening state has just changed. It is necessary to
            ! allow this increase in error so the Jacobian can be calculated on "this side" of the crack state.
            Continue
          Else

            Call log%info('Solution is diverging, err: ' // trim(str(err)) // ' > ' // trim(str(err_old)))

            ! Cut-back using the current starting point
            If (cutbacks .LT. p%cutbacks_max) Then
              Cutback = .True.

            ! Restart using a new starting point, if available
            Else
              Restart = .True.
            End If

            Cycle Equilibrium

          End If

        End If

        ! Ensures that an artificial no "sliding condition" is not forced as the solution
        If (err .LT. tol_DGD .AND. forced_sticking .EQ. 1 .AND. .NOT. crack_open) Then
          If (Sliding .NEQV. crack_is_sliding(delta_coh(:,Q), Pen, slide_old, m%mu, m%mu)) Then
            forced_sticking = 2  ! Deactivates forced "no sliding" condition
            err = Huge(zero)  ! Resets the error. An increase in error here does not indicate divergence.
            Cycle Equilibrium
          End If
        End If

        ! Check for any inside-out deformation or an overly compressed bulk material
        If (err .LT. tol_DGD .AND. MDet(F_bulk) .LT. p%compLimit) Then

          Call log%warn('det(F_bulk) is below limit: ' // trim(str(MDet(F_bulk))) // ' Restart: ' // trim(str(restarts)))

          ! Restart using new starting point
          Restart = .True.
          Cycle Equilibrium
        End If

        ! If converged,
        If (err .LT. tol_DGD) Then

          Call log%debug('Equilibrium loop found a converged solution.')

          sv%Fb1 = F_bulk(1,Q); sv%Fb2 = F_bulk(2,Q); sv%Fb3 = F_bulk(3,Q)

          ! Update fiber damage state variables
          sv%d1T = d1T_temp
          sv%d1C = d1C_temp
          sv%rfT = rfT_temp
          sv%rfC = rfC_temp

          ! Update shear nonlinearity state variables
          sv%Plas12 = Plas12_temp
          sv%Inel12 = Inel12_temp
          sv%Sr = Sr_temp

          ! If fully damaged
          If (sv%d2 .GE. damage_max) Then
            sv%d2 = damage_max
            sv%FIm = one
            EXIT MatrixDamage
          End If
          EXIT Equilibrium ! Check for change in sv%d2
        End If

        ! -------------------------------------------------------------------- !
        !    Find the derivative of the Cauchy stress tensor.                  !
        ! -------------------------------------------------------------------- !
        F_bulk_d    = zero
        R_cr_d      = zero
        delta_coh_d = zero
        eps_d       = zero
        stress_d    = zero
        Cauchy_d    = zero
        T_d         = zero
        T_coh_d     = zero

        Do I=1,3
          F_bulk_d(I,Q,I) = one

          ! info on derivative of x/||x||: http://blog.mmacklin.com/2012/05/
          R_cr_d(:,2,I) = -MATMUL(MATMUL(TRANSPOSE(F_bulk_inverse), MATMUL(TRANSPOSE(F_bulk_d(:,:,I)), TRANSPOSE(F_bulk_inverse))), normal)
          ! info on derivative of inverse matrix: http://planetmath.org/derivativeofinversematrix
          R_cr_d(:,2,I) = MATMUL(eye/r2length - OuterProduct(R_cr(:,2), R_cr(:,2))/r2length, R_cr_d(:,2,I))
          R_cr_d(:,3,I) = CrossProduct(R_cr(:,1), R_cr_d(:,2,I))

          delta_coh_d(:,Q,I) = MATMUL(TRANSPOSE(R_cr_d(:,:,I)), (F(:,Q) - F_bulk(:,Q)))*X(Q,Q) - MATMUL(TRANSPOSE(R_cr), F_bulk_d(:,Q,I))*X(Q,Q)

          If (crack_open) Then ! Open cracks
            T_coh_d(:,I) = Pen(:)*(one - sv%d2)*delta_coh_d(:,Q,I)

          Else If (.NOT. m%friction) Then ! Closed cracks without friction
            T_coh_d(1,I) = Pen(1)*(one - sv%d2)*delta_coh_d(1,Q,I)
            T_coh_d(2,I) = Pen(2)*delta_coh_d(2,Q,I)
            T_coh_d(3,I) = Pen(3)*(one - sv%d2)*delta_coh_d(3,Q,I)

          Else If (Sliding) Then ! Closed cracks with sliding friction
            T_coh_d_den_temp = (Pen(1)*(delta_coh(1,Q) - slide_old(1)))**2 + (Pen(3)*(delta_coh(3,Q) - slide_old(2)))**2

            T_coh_d(1,I) = Pen(1)*(one - sv%d2)*delta_coh_d(1,Q,I)
            T_coh_d(3,I) = Pen(3)*(one - sv%d2)*delta_coh_d(3,Q,I)

            If (T_coh_d_den_temp .NE. zero) Then
              T_coh_d(1,I) = T_coh_d(1,I) - AdAe*m%mu*Pen(2)*Pen(1)/SQRT(T_coh_d_den_temp)* &
                (delta_coh_d(2,Q,I)*(delta_coh(1,Q) - slide_old(1)) + delta_coh(2,Q)*delta_coh_d(1,Q,I) - delta_coh(2,Q)*(delta_coh(1,Q) - slide_old(1))* &
                (Pen(1)*Pen(1)*(delta_coh(1,Q) - slide_old(1))*delta_coh_d(1,Q,I) + &
                 Pen(3)*Pen(3)*(delta_coh(3,Q) - slide_old(2))*delta_coh_d(3,Q,I))/T_coh_d_den_temp)

              T_coh_d(3,I) = T_coh_d(3,I) - AdAe*m%mu*Pen(2)*Pen(3)/SQRT(T_coh_d_den_temp)* &
                (delta_coh_d(2,Q,I)*(delta_coh(3,Q) - slide_old(2)) + delta_coh(2,Q)*delta_coh_d(3,Q,I) - delta_coh(2,Q)*(delta_coh(3,Q) - slide_old(2))* &
                (Pen(1)*Pen(1)*(delta_coh(1,Q) - slide_old(1))*delta_coh_d(1,Q,I) + &
                 Pen(3)*Pen(3)*(delta_coh(3,Q) - slide_old(2))*delta_coh_d(3,Q,I))/T_coh_d_den_temp)
            End If
            T_coh_d(2,I) = Pen(2)*delta_coh_d(2,Q,I)

          Else ! Closed cracks with sticking friction
            T_coh_d(1,I) = Pen(1)*(one - sv%d2 + AdAe)*delta_coh_d(1,Q,I)
            T_coh_d(2,I) = Pen(2)*delta_coh_d(2,Q,I)
            T_coh_d(3,I) = Pen(3)*(one - sv%d2 + AdAe)*delta_coh_d(3,Q,I)
          End If

          eps_d(:,:,I) = (MATMUL(TRANSPOSE(F_bulk_d(:,:,I)), F_bulk) + MATMUL(TRANSPOSE(F_bulk), F_bulk_d(:,:,I)))/two
          stress_d(:,:,I) = Hooke(Stiff,eps_d(:,:,I),nshr)

          Y = MATMUL(F_bulk_inverse, F_bulk_d(:,:,I))
          tr = Y(1,1) + Y(2,2) + Y(3,3)
          Cauchy_d(:,:,I) = (MATMUL(MATMUL(F_bulk_d(:,:,I), stress) + MATMUL(F_bulk, stress_d(:,:,I)), TRANSPOSE(F_bulk)) + MATMUL(MATMUL(F_bulk, stress), TRANSPOSE(F_bulk_d(:,:,I))))/MDet(F_bulk) - Cauchy*tr

          T_d(:,I) = MATMUL(Cauchy_d(:,:,I), R_cr(:,2)) + MATMUL(Cauchy, R_cr_d(:,2,I))
        End Do

        ! -------------------------------------------------------------------- !
        !    Define the Jacobian matrix, J                                     !
        ! -------------------------------------------------------------------- !
        Jac = zero

        Jac(:,1) = T_coh_d(:,1) - MATMUL(TRANSPOSE(R_cr), T_d(:,1)) - MATMUL(TRANSPOSE(R_cr_d(:,:,1)), T)
        Jac(:,2) = T_coh_d(:,2) - MATMUL(TRANSPOSE(R_cr), T_d(:,2)) - MATMUL(TRANSPOSE(R_cr_d(:,:,2)), T)
        Jac(:,3) = T_coh_d(:,3) - MATMUL(TRANSPOSE(R_cr), T_d(:,3)) - MATMUL(TRANSPOSE(R_cr_d(:,:,3)), T)

        ! -------------------------------------------------------------------- !
        !    Calculate the new bulk deformation gradient                       !
        ! -------------------------------------------------------------------- !
        F_bulk_old(:)    = F_bulk(:,Q)
        F_bulk_change(:) = MATMUL(MInverse(Jac), Residual)
        F_bulk(:,Q)      = F_bulk_old(:) - F_bulk_change(:)*aid

        ! -------------------------------------------------------------------- !
        !    Check for a change in crack opening                               !
        ! -------------------------------------------------------------------- !

        ! Store the previous crack opening state variable
        crack_was_open = crack_open

        ! Update the crack opening state variable
        R_cr(:,2) = Norm(MATMUL(MInverse(TRANSPOSE(F_bulk)), normal))
        R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

        delta_coh(:,Q) = MATMUL(TRANSPOSE(R_cr), F(:,Q) - F_bulk(:,Q))*X(Q,Q)

        If (delta_coh(2,Q) .GE. zero) Then
          crack_open = .True.
        Else
          crack_open = .False.
        End If

        crack_inflection_aid = one

        ! Check for a change in the crack opening state
        If (crack_open .EQV. crack_was_open) Then
          ! If there is no change, do nothing.
          crack_inverted = .False.

        Else If (crack_inversions .LT. crack_inversions_max) Then
          If (crack_open) Then
            Call log%info('Change in crack opening. Crack now open.')
          Else
            Call log%info('Change in crack opening. Crack now closed.')
          End If
          crack_inversions = crack_inversions + 1
          crack_inverted = .True.

          ! Initialize a test variable for the crack opening state
          crack_open_test = crack_open

          ! Loop until the crack opening status changes back
          Do While (crack_open_test .EQV. crack_open)

            crack_inflection_aid = crack_inflection_aid * crack_inflection_cutback

            F_bulk(:,Q) = F_bulk_old(:) - F_bulk_change(:)*aid*crack_inflection_aid

            R_cr(:,2) = Norm(MATMUL(MInverse(TRANSPOSE(F_bulk)), normal))
            R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

            delta_coh(:,Q) = MATMUL(TRANSPOSE(R_cr), F(:,Q) - F_bulk(:,Q))*X(Q,Q)

            If (delta_coh(2,Q) .GE. zero) Then
              crack_open_test = .True.
            Else
              crack_open_test = .False.
            End If

          End Do

          ! Return F_bulk to the state immediately before the crack state changed back
          crack_inflection_aid = crack_inflection_aid / crack_inflection_cutback
          F_bulk(:,Q) = F_bulk_old(:) - F_bulk_change(:)*aid*crack_inflection_aid

        Else
          crack_inverted = .False.
        End If
      End Do Equilibrium


      Call log%debug('Exited Equilibrium loop.')

      ! Store the old cohesive damage variable for checking for convergence
      damage_old = sv%d2

      If (MD .EQ. 1) delta_n_init = MIN(zero, delta_coh(2,Q))

      ! Update the cohesive damage variable
      Call cohesive_damage(m, delta_coh(:,Q), Pen, delta_n_init, sv%B, sv%FIm, sv%d2, dGdGc)

      ! Check for damage advancement
      If (sv%d2 .LE. damage_old) Then  ! If there is no damage progression,
        Call log%debug('No change in matrix damage variable, d2 ' // trim(str(sv%d2)))
        EXIT MatrixDamage
      Else
        Call log%debug('Change in matrix damage variable, d2 ' // trim(str(sv%d2)))
      End If

      ! Check for convergence based on rate of energy dissipation
      If (dGdGc .LT. p%dGdGc_min) Then
        Call log%info('Solution accepted due to small change in dmg.')
        Call log%info('MD: ' // trim(str(MD)) // ' AdAe: ' // trim(str(AdAe)))
        EXIT MatrixDamage
      End If

      ! Limit number of MatrixDamage loop iterations
      If (MD .GT. p%MD_max) Then
        Call log%info('MatrixDamage loop limit exceeded. MD: ' // trim(str(MD)))
        Call log%info('dGdGc: ' // trim(str(dGdGc)) // ' AdAe: ' // trim(str(AdAe)))
        EXIT MatrixDamage
      End If

    End Do MatrixDamage


    Call log%info('Exited matrix damage loop, MD: ' // trim(str(MD)))

    ! -------------------------------------------------------------------- !
    !    Update elastic energy variable.                                   !
    ! -------------------------------------------------------------------- !
    enerIntern = zero
    Do I=1,3
      Do J=1,3
        enerIntern = enerIntern + 0.5d0*stress(I,J)*eps(I,J)
      End Do
    End Do

    ! -------------------------------------------------------------------- !
    Return
  End Subroutine DGDEvolve


  Subroutine DGDKinkband(U,F,F_old,m,p,sv,ndir,nshr,DT,Cauchy,enerIntern)

    Use forlog_Mod
    Use matrixAlgUtil_Mod
    Use matProp_Mod
    Use stateVar_Mod
    Use parameters_Mod
    Use stress_Mod
    Use strain_mod

    Include 'vaba_param.inc'

    ! -------------------------------------------------------------------- !
    ! Arguments
    Type(matProps), intent(IN) :: m
    Type(parameters), intent(IN) :: p
    Type(stateVars), intent(INOUT) :: sv
    Double Precision, Intent(IN) :: F(3,3), U(3,3), F_old(3,3)               ! Deformation gradient, stretch tensor
    Double Precision, Intent(IN) :: DT                                       ! Delta temperature
    Integer, intent(IN) :: ndir, nshr
    Double Precision, Intent(OUT) :: Cauchy(ndir,ndir)
    Double Precision, Intent(OUT) :: enerIntern

    ! -------------------------------------------------------------------- !
    ! Locals
    Double Precision :: Stiff(ndir+nshr,ndir+nshr)                           ! Stiffness
    Double Precision :: R_cr(3,3)                                            ! Basis coordinate system for the cohesive surface
    Double Precision :: normalDir(3)                                         ! Normal to the crack plane in the reference configuration
    Double Precision :: fiberDir(3)                                          ! Current fiber direction
    Double Precision :: gamma_rphi0                                          ! Shear strain in the misaligned frame
    Double Precision :: X(ndir,ndir)                                         ! Reference configuration
    Double Precision :: eye(ndir,ndir)
    Double Precision :: U_bulk(3,3)
    Double Precision :: R_phi0(3,3)                                          ! Transformation to the misaligned frame from the reference frame
    Double Precision :: E1

    ! Kinkband region
    Double Precision :: Fkb(3,3)
    Double Precision :: Fkb_inverse(3,3)
    Double Precision :: Fkb_old(3,3)
    Double Precision :: epskb(ndir,ndir)
    Double Precision :: pk2_fiberDirkb(3,3)
    Double Precision :: stresskb(ndir,ndir)
    Double Precision :: Cauchykb(ndir,ndir)
    Double Precision :: Tkb(3)
    Double Precision :: eps12kb_dir

    ! Material region
    Double Precision :: Fm(3,3)
    Double Precision :: epsm(ndir,ndir)
    Double Precision :: pk2_fiberDirm(3,3)
    Double Precision :: stressm(ndir,ndir)
    Double Precision :: Cauchym(ndir,ndir)
    Double Precision :: Tm(3)

    ! Shear nonlinearity
    Double Precision :: Plas12_temp, Inel12_temp

    ! Constants
    Double Precision, parameter :: zero=0.d0, one=1.d0, two=2.d0
    Double Precision, parameter :: pert=0.0001d0                             ! Small perturbation used to compute a numerical derivative

    ! Internal convergence
    Integer :: EQk                                                           ! Equilibrium loop index
    Double Precision :: Residual(3)                                          ! Residual stress vector
    Double Precision :: x_change(3)
    Double Precision :: tol_DGD
    Double Precision :: err, err_old
    Double Precision :: aid

    ! Jacobian
    Double Precision :: Jac(3,3)
    Double Precision :: dFkb_dFkb1(3,3,3)
    Double Precision :: dR_cr_dFkb1(3,3,3)
    Double Precision :: dFm_dFkb1(3,3,3)
    Double Precision :: dEm_dFkb1(3,3,3)
    Double Precision :: dSm_dFkb1(3,3,3)
    Double Precision :: dCauchym_dFkb1(3,3,3)
    Double Precision :: dTm_dFkb1(3,3)
    Double Precision :: dEkb_dFkb1(3,3,3)
    Double Precision :: dSkb_dFkb1(3,3,3)
    Double Precision :: dCauchykb_dFkb1(3,3,3)
    Double Precision :: dTkb_dFkb1(3,3)
    Double Precision :: Ym(3,3), Ykb(3,3)

    ! -------------------------------------------------------------------- !

    ! Initialize
    aid = one
    sv%gamma = zero
    X = zero; X(1,1) = sv%Lc(1); X(2,2) = sv%Lc(2); X(3,3) = sv%Lc(3) ! Ref. Config.
    eye = zero; DO I = 1,3; eye(I,I) = one; end DO ! Identity Matrix
    tol_DGD = m%YT*p%tol_DGD_f ! Equilibrium loop tolerance [stress]

    ! -------------------------------------------------------------------- !
    !    Starting point                                                    !
    ! -------------------------------------------------------------------- !
    Fm(:,:) = F(:,:)
    Fkb(:,:) = F(:,:); Fkb(1,1) = sv%Fb1; Fkb(2,1) = sv%Fb2; Fkb(3,1) = sv%Fb3

    ! Make sure that we have a valid starting point
    If (Length(Fkb(:,1)) .EQ. zero) Fkb(1,1) = one

    ! Normal to misaligned fibers (reference config)
    normalDir = (/-sin(sv%phi0), cos(sv%phi0), zero/)

    ! Misalgined fiber direction (reference config)
    fiberDir = (/cos(sv%phi0), sin(sv%phi0), zero/)

    ! Build R_phi0 matrix
    R_phi0(:,1) = fiberDir
    R_phi0(:,2) = normalDir
    R_phi0(:,3) = (/zero, zero, one/)

    ! Initialize
    Fkb_old = F_old
    Fkb_old(:,1) = (/sv%Fb1, sv%Fb2, sv%Fb3/)

    ! -------------------------------------------------------------------- !
    !    Equilibrium Loop and solution controls definition                 !
    ! -------------------------------------------------------------------- !
    err = Huge(zero)
    EQk = 0

    Equilibrium: Do ! Loop to determine the current Fkb(:,1)
      EQk = EQk + 1
      If (EQk .GT. p%EQ_max) Then
        Call writeDGDArgsToFile(m,p,sv,U,F,F_old,ndir,nshr,DT)
        Call log%warn('Equilibrium loop reached maximum number of iterations.')
        sv%STATUS = 0
        Exit Equilibrium
      End If
      Call log%debug('Equilibrium Start.')

      ! -------------------------------------------------------------------- !
      ! Initialize all temporary state variables for use in Equilibrium loop:

      ! Shear nonlinearity temporary variables. Start each equilibrium iteration with the
      ! converged values of Plas12 and Inel12 from the last increment.
      Plas12_temp = sv%Plas12
      Inel12_temp = sv%Inel12

      ! -------------------------------------------------------------------- !
      ! Compatibility constraints
      Fm(:,1) = (F(:,1)*sv%Lc(1) - Fkb(:,1)*m%w_kb)/(sv%Lc(1)-m%w_kb)

      ! Store re-used matrices
      Fkb_inverse = MInverse(Fkb)

      ! -------------------------------------------------------------------- !
      ! Define the current crack coordinate system
      R_cr(:,1) = MATMUL(Fkb, fiberDir)
      r1length = Length(R_cr(:,1))    ! Un-normalized length of R_cr(:,1), used in the Jacobian
      R_cr(:,1) = R_cr(:,1)/r1length  ! Normalized R_cr(:,2)
      R_cr(:,2) = MATMUL(TRANSPOSE(Fkb_inverse), normalDir)
      r2length = Length(R_cr(:,2))    ! Un-normalized length of R_cr(:,2), used in the Jacobian
      R_cr(:,2) = R_cr(:,2)/r2length  ! Normalized R_cr(:,2)
      R_cr(:,3) = CrossProduct(R_cr(:,1), R_cr(:,2))

      ! Calculate the angle that define the rotation of the fibers
      sv%gamma = ATAN(R_cr(2,1)/R_cr(1,1)) - sv%phi0

      ! TODO for other strain component implementation: Calculate U_bulk from F_bulk
      U_bulk = zero

      ! Calculate the sign of the change in shear strain (for shear nonlinearity subroutine)
      If (m%shearNonlinearity) Then
        eps12kb_dir = Sign(one, (Fkb(1,1)*Fkb(1,2) + Fkb(2,1)*Fkb(2,2) + Fkb(3,1)*Fkb(3,2)) - (sv%Fb1*Fkb_old(1,2) + sv%Fb2*Fkb_old(2,2) + sv%Fb3*Fkb_old(3,2)))
      End If

      ! -------------------------------------------------------------------- !
      !    Calculate the stress in the bulk material region:                 !
      ! -------------------------------------------------------------------- !
      epsm = GLStrain(Fm,ndir)
      epsm = MATMUL(TRANSPOSE(R_phi0), MATMUL(epsm, R_phi0))
      E1 = m%E1*(1+m%gammaf*epsm(1,1))
      Stiff = StiffFunc(ndir+nshr, E1, m%E2, m%E3, m%G12, m%G13, m%G23, m%v12, m%v13, m%v23, zero, zero, zero)
      pk2_fiberDirm = Hooke(Stiff, epsm, nshr) ! 2PK
      stressm = MATMUL(R_phi0, MATMUL(pk2_fiberDirm, TRANSPOSE(R_phi0)))  ! 2PK rotated back to the reference direction
      Cauchym = convertToCauchy(stressm, m%strainDef, Fm, U_bulk)
      Tm = MATMUL(Cauchym, R_cr(:,1))  ! Traction on surface with normal in fiber direction

      ! -------------------------------------------------------------------- !
      !    Calculate the stress in the kinkband bulk region:                 !
      ! -------------------------------------------------------------------- !
      Call Strains(Fkb, m, U_bulk, DT, ndir, epskb, Plas12_temp, Inel12_temp, eps12kb_dir, sv%STATUS, p%gamma_max, E1, R_phi0)
      gamma_rphi0 = two*(epskb(1,2) + Plas12_temp/two)
      Stiff = StiffFunc(ndir+nshr, E1, m%E2, m%E3, m%G12, m%G13, m%G23, m%v12, m%v13, m%v23, zero, zero, zero)
      pk2_fiberDirkb = Hooke(Stiff, epskb, nshr) ! 2PK in the fiber direction
      stresskb = MATMUL(R_phi0, MATMUL(pk2_fiberDirkb, TRANSPOSE(R_phi0)))  ! 2PK rotated back to the reference direction
      Cauchykb = convertToCauchy(stresskb, m%strainDef, Fkb, U_bulk)
      Cauchy = Cauchykb
      Tkb = MATMUL(Cauchykb, R_cr(:,1))  ! Traction on surface with normal in fiber direction

      ! Failure index for fiber kinking
      sv%rfC = abs((-1*Cauchy(1,1)*cos(two*(sv%phi0+gamma_rphi0)))/((ramberg_osgood(gamma_rphi0 + pert, m%G12, m%aPL, m%nPL) - ramberg_osgood(gamma_rphi0 - pert, m%G12, m%aPL, m%nPL)) / (two * pert)))

      ! -------------------------------------------------------------------- !
      !    Define the stress residual vector, R. R is equal to the           !
      !    difference in stress between the cohesive interface and the bulk  !
      !    stress projected onto the cohesive interface                      !
      ! -------------------------------------------------------------------- !
      Residual(1:3) = MATMUL(TRANSPOSE(R_cr), Tm) - MATMUL(TRANSPOSE(R_cr), Tkb)

      ! -------------------------------------------------------------------- !
      !    Check for convergence.                                            !
      ! -------------------------------------------------------------------- !
      err_old = err
      err = Length(Residual)
      percentChangeInErr = (err - err_old)/err_old
      Call log%debug('The error is: ' // trim(str(err)))

      ! Do not bother to attempt to find equilibrium if the element was deleted in Strains
      If (sv%STATUS .EQ. 0) Then
        EXIT Equilibrium
      End If

      ! Check for any inside-out deformation or an overly compressed bulk material
      If (err .LT. tol_DGD .AND. MDet(Fkb) .LT. p%compLimit) Then
        Call log%info('Deleting failed element for which no solution could be found.')
        sv%STATUS = 0
        EXIT Equilibrium
      End If

      ! If converged,
      If (err .LT. tol_DGD) Then

        ! Save starting point
        sv%Fb1 = Fkb(1,1); sv%Fb2 = Fkb(2,1); sv%Fb3 = Fkb(3,1)

        ! Update shear nonlinearity state variables
        sv%Plas12 = Plas12_temp
        sv%Inel12 = Inel12_temp

        EXIT Equilibrium
      End If

      ! -------------------------------------------------------------------- !
      !    Find the derivative of the Cauchy stress tensor.                  !
      ! -------------------------------------------------------------------- !
      ! Initialize
      dFkb_dFkb1 = zero
      dR_cr_dFkb1 = zero
      dFm_dFkb1 = zero
      dEm_dFkb1 = zero
      dSm_dFkb1 = zero
      dCauchym_dFkb1 = zero
      dTm_dFkb1 = zero
      dEkb_dFkb1 = zero
      dSkb_dFkb1 = zero
      dCauchykb_dFkb1 = zero
      dTkb_dFkb1 = zero
      Jac = zero

      DO I=1,3

        dFkb_dFkb1(I,1,I) = one

        ! Coordinate system
        ! dR_cr_dFkb1
        dR_cr_dFkb1(:,1,I) = MATMUL(eye/r1length - OuterProduct(R_cr(:,1), R_cr(:,1))/r1length, MATMUL(dFkb_dFkb1(:,:,I), fiberDir))
        dR_cr_dFkb1(:,2,I) = -MATMUL(MATMUL(TRANSPOSE(Fkb_inverse), MATMUL(TRANSPOSE(dFkb_dFkb1(:,:,I)), TRANSPOSE(Fkb_inverse))), normalDir)
        dR_cr_dFkb1(:,2,I) = MATMUL(eye/r2length - OuterProduct(R_cr(:,2), R_cr(:,2))/r2length, dR_cr_dFkb1(:,2,I))
        ! cross product
        dR_cr_dFkb1(:,3,I) =  CrossProduct(dR_cr_dFkb1(:,1,I), R_cr(:,2)) +  CrossProduct(R_cr(:,1), dR_cr_dFkb1(:,2,I))

        ! --- dsigm/dFkb1
        ! Bulk material
        dFm_dFkb1(I,1,I) = -m%w_kb/(X(1,1)-m%w_kb);
        dEm_dFkb1(:,:,I) = (MATMUL(TRANSPOSE(dFm_dFkb1(:,:,I)), Fm) + MATMUL(TRANSPOSE(Fm), dFm_dFkb1(:,:,I)))/two
        dEm_dFkb1(:,:,I) = MATMUL(TRANSPOSE(R_phi0), MATMUL(dEm_dFkb1(:,:,I), R_phi0))
        dSm_dFkb1(:,:,I) = Hooke(Stiff, dEm_dFkb1(:,:,I), nshr)
        dSm_dFkb1(:,:,I) = MATMUL(R_phi0, MATMUL(dSm_dFkb1(:,:,I), TRANSPOSE(R_phi0)))
        Ym = MATMUL(MInverse(Fm), dFm_dFkb1(:,:,I))
        tr = Ym(1,1) + Ym(2,2) + Ym(3,3)
        dCauchym_dFkb1(:,:,I) = (MATMUL(MATMUL(dFm_dFkb1(:,:,I), stressm) + MATMUL(Fm, dSm_dFkb1(:,:,I)), TRANSPOSE(Fm)) + MATMUL(MATMUL(Fm, stressm), TRANSPOSE(dFm_dFkb1(:,:,I))))/MDet(Fm) - Cauchym*tr
        dTm_dFkb1(:,I) = MATMUL(dCauchym_dFkb1(:,:,I), R_cr(:,1)) + MATMUL(Cauchym, dR_cr_dFkb1(:,1,I))

        ! Kinkband bulk
        dEkb_dFkb1(:,:,I) = (MATMUL(TRANSPOSE(dFkb_dFkb1(:,:,I)), Fkb) + MATMUL(TRANSPOSE(Fkb), dFkb_dFkb1(:,:,I)))/two
        dEkb_dFkb1(:,:,I) = MATMUL(TRANSPOSE(R_phi0), MATMUL(dEkb_dFkb1(:,:,I), R_phi0))
        dSkb_dFkb1(:,:,I) = Hooke(Stiff, dEkb_dFkb1(:,:,I), nshr)
        dSkb_dFkb1(:,:,I) = MATMUL(R_phi0, MATMUL(dSkb_dFkb1(:,:,I), TRANSPOSE(R_phi0)))
        Ykb = MATMUL(MInverse(Fkb), dFkb_dFkb1(:,:,I))
        tr = Ykb(1,1) + Ykb(2,2) + Ykb(3,3)
        dCauchykb_dFkb1(:,:,I) = (MATMUL(MATMUL(dFkb_dFkb1(:,:,I), stresskb) + MATMUL(Fkb, dSkb_dFkb1(:,:,I)), TRANSPOSE(Fkb)) + MATMUL(MATMUL(Fkb, stresskb), TRANSPOSE(dFkb_dFkb1(:,:,I))))/MDet(Fkb) - Cauchykb*tr
        dTkb_dFkb1(:,I) = MATMUL(dCauchykb_dFkb1(:,:,I), R_cr(:,1)) + MATMUL(Cauchykb, dR_cr_dFkb1(:,1,I))

        ! Contribution to jacobian
        Jac(:,i) = MATMUL(TRANSPOSE(dR_cr_dFkb1(:,:,i)), Tm) + MATMUL(TRANSPOSE(R_cr), dTm_dFkb1(:,i)) - (MATMUL(TRANSPOSE(dR_cr_dFkb1(:,:,i)), Tkb) + MATMUL(TRANSPOSE(R_cr), dTkb_dFkb1(:,i)));

      End Do

      ! -------------------------------------------------------------------- !
      ! Calculate the new Fkb
      x_change(:) = MATMUL(MInverse(Jac), Residual)
      Fkb(:,1) = Fkb(:,1) - x_change*aid

    End Do Equilibrium

    ! -------------------------------------------------------------------- !
    !    Update elastic energy variable.                                   !
    ! -------------------------------------------------------------------- !
    enerIntern = zero
    Do I=1,3
      Do J=1,3
        enerIntern = enerIntern + 0.5d0*stressm(I,J)*epsm(I,J)
      End Do
    End Do

    ! -------------------------------------------------------------------- !
    Return
  End Subroutine DGDKinkband


  Subroutine writeDGDArgsToFile(m,p,sv,U,F,F_old,ndir,nshr,DT)
    ! Print DGDEvolve args at error

    Use matProp_Mod
    Use stateVar_Mod
    Use parameters_Mod

    ! Arguments
    Type(matProps), intent(IN) :: m
    Type(parameters), intent(IN) :: p
    Type(stateVars), intent(IN) :: sv
    Double Precision, Intent(IN) :: F(3,3), U(3,3), F_old(3,3)               ! Deformation gradient, stretch tensor
    Double Precision, Intent(IN) :: DT                                       ! Delta temperature
    Integer, intent(IN) :: ndir, nshr

    Integer :: lenOutputDir
    Character(len=256) :: outputDir, fileName
    Character(len=32) :: nameValueFmt

#ifndef PYEXT
    Call VGETOUTDIR(outputDir, lenOutputDir)
    fileName = trim(outputDir) // '/debug.py'  ! Name of output file

    nameValueFmt = "(A,E21.15E2,A)"

    open(unit = 101, file = fileName)
    write(101,"(A)") 'featureFlags = {'
    If (m%matrixDam) Then
      write(101,"(A)") '    "matrixDam": True,'
    Else
      write(101,"(A)") '    "matrixDam": False,'
    End If
    If (m%shearNonlinearity) Then
      write(101,"(A)") '    "shearNonlinearity": True,'
    Else
      write(101,"(A)") '    "shearNonlinearity": False,'
    End If
    If (m%fiberTenDam) Then
      write(101,"(A)") '    "fiberTenDam": True,'
    Else
      write(101,"(A)") '    "fiberTenDam": False,'
    End If
    If (m%fiberCompDamBL) Then
      write(101,"(A)") '    "fiberCompDamBL": True,'
    Else
      write(101,"(A)") '    "fiberCompDamBL": False,'
    End If
    If (m%friction) Then
      write(101,"(A)") '    "friction": True'
    Else
      write(101,"(A)") '    "friction": False'
    End If
    write(101, "(A)") '}'
    write(101, "(A)") 'm = {'
    write(101, nameValueFmt) '    "E1": ', m%E1, ','
    write(101, nameValueFmt) '    "E2": ', m%E2, ','
    write(101, nameValueFmt) '    "G12": ', m%G12, ','
    write(101, nameValueFmt) '    "v12": ', m%v12, ','
    write(101, nameValueFmt) '    "v23": ', m%v23, ','
    write(101, nameValueFmt) '    "YT": ', m%YT, ','
    write(101, nameValueFmt) '    "SL": ', m%SL, ','
    write(101, nameValueFmt) '    "GYT": ', m%GYT, ','
    write(101, nameValueFmt) '    "GSL": ', m%GSL, ','
    write(101, nameValueFmt) '    "eta_BK": ', m%eta_BK, ','
    write(101, nameValueFmt) '    "YC": ', m%YC, ','
    write(101, nameValueFmt) '    "alpha0": ', m%alpha0, ','
    write(101, nameValueFmt) '    "E3": ', m%E3, ','
    write(101, nameValueFmt) '    "G13": ', m%G13, ','
    write(101, nameValueFmt) '    "G23": ', m%G23, ','
    write(101, nameValueFmt) '    "v13": ', m%v13, ','
    write(101, "(A)") '    "cte": ['
    write(101, nameValueFmt) '        ', m%cte(1), ','
    write(101, nameValueFmt) '        ', m%cte(2), ','
    write(101, nameValueFmt) '        ', m%cte(3)
    write(101, "(A)") '    ],'
    write(101, nameValueFmt) '    "aPL": ', m%aPL, ','
    write(101, nameValueFmt) '    "nPL": ', m%nPL, ','
    write(101, nameValueFmt) '    "XT": ', m%XT, ','
    write(101, nameValueFmt) '    "fXT": ', m%fXT, ','
    write(101, nameValueFmt) '    "GXT": ', m%GXT, ','
    write(101, nameValueFmt) '    "fGXT": ', m%fGXT, ','
    write(101, nameValueFmt) '    "XC": ', m%XC, ','
    write(101, nameValueFmt) '    "fXC": ', m%fXC, ','
    write(101, nameValueFmt) '    "GXC": ', m%GXC, ','
    write(101, nameValueFmt) '    "fGXC": ', m%fGXC, ','
    write(101, nameValueFmt) '    "mu": ', m%mu
    write(101, "(A)") '}'
    write(101, "(A)") 'p = {'
    write(101, "(A,I1,A)")   '    "cutbacks_max": ', p%cutbacks_max, ','
    write(101, "(A,I5,A)")   '    "MD_max": ', p%MD_max, ','
    write(101, "(A,I2,A)")   '    "alpha_inc": ', p%alpha_inc, ','
    write(101, nameValueFmt) '    "tol_DGD_f": ', p%tol_DGD_f, ','
    write(101, nameValueFmt) '    "dGdGc_min": ', p%dGdGc_min, ','
    write(101, nameValueFmt) '    "compLimit": ', p%compLimit, ','
    write(101, nameValueFmt) '    "penStiffMult": ', p%penStiffMult, ','
    write(101, nameValueFmt) '    "cutback_amount": ', p%cutback_amount, ','
    write(101, nameValueFmt) '    "tol_divergence": ', p%tol_divergence
    write(101, "(A)") '}'
    write(101, "(A)") 'sv = {'
    write(101, nameValueFmt) '    "d2": ', sv%d2, ','
    write(101, nameValueFmt) '    "Fb1": ', sv%Fb1, ','
    write(101, nameValueFmt) '    "Fb2": ', sv%Fb2, ','
    write(101, nameValueFmt) '    "Fb3": ', sv%Fb3, ','
    write(101, nameValueFmt) '    "B": ', sv%B, ','
    write(101, nameValueFmt) '    "rfT": ', sv%rfT, ','
    write(101, nameValueFmt) '    "FIm": ', sv%FIm, ','
    write(101, "(A,I5,A)")   '    "alpha": ', sv%alpha, ','
    write(101, "(A,I1,A)")   '    "STATUS": ', sv%STATUS, ','
    write(101, nameValueFmt) '    "Plas12": ', sv%Plas12, ','
    write(101, nameValueFmt) '    "Inel12": ', sv%Inel12, ','
    write(101, "(A)") '    "slide": ['
    write(101, nameValueFmt) '        ', sv%slide(1), ','
    write(101, nameValueFmt) '        ', sv%slide(2)
    write(101, "(A)") '    ],'
    write(101, nameValueFmt) '    "rfC": ', sv%rfC, ','
    write(101, nameValueFmt) '    "d1T": ', sv%d1T, ','
    write(101, nameValueFmt) '    "d1C": ', sv%d1C, ','
    write(101, nameValueFmt) '    "phi0": ', sv%phi0, ','
    write(101, nameValueFmt) '    "gamma": ', sv%gamma
    write(101, "(A)") '}'
    write(101, "(A)") 'Lc = ['
    write(101, nameValueFmt) '    ', sv%Lc(1), ','
    write(101, nameValueFmt) '    ', sv%Lc(2), ','
    write(101, nameValueFmt) '    ', sv%Lc(3), ','
    write(101, "(A)") ']'
    write(101, "(A)") 'U = ['
    write(101, nameValueFmt) '    ', U(1,1), ','
    write(101, nameValueFmt) '    ', U(2,2), ','
    write(101, nameValueFmt) '    ', U(3,3), ','
    write(101, nameValueFmt) '    ', U(1,2), ','
    write(101, nameValueFmt) '    ', U(2,3), ','
    write(101, nameValueFmt) '    ', U(3,1), ','
    write(101, nameValueFmt) '    ', U(2,1), ','
    write(101, nameValueFmt) '    ', U(3,2), ','
    write(101, nameValueFmt) '    ', U(1,3), ','
    write(101, "(A)") ']'
    write(101, "(A)") 'F = ['
    write(101, nameValueFmt) '    ', F(1,1), ','
    write(101, nameValueFmt) '    ', F(2,2), ','
    write(101, nameValueFmt) '    ', F(3,3), ','
    write(101, nameValueFmt) '    ', F(1,2), ','
    write(101, nameValueFmt) '    ', F(2,3), ','
    write(101, nameValueFmt) '    ', F(3,1), ','
    write(101, nameValueFmt) '    ', F(2,1), ','
    write(101, nameValueFmt) '    ', F(3,2), ','
    write(101, nameValueFmt) '    ', F(1,3), ','
    write(101, "(A)") ']'
    write(101, "(A)") 'F_old = ['
    write(101, nameValueFmt) '    ', F_old(1,1), ','
    write(101, nameValueFmt) '    ', F_old(2,2), ','
    write(101, nameValueFmt) '    ', F_old(3,3), ','
    write(101, nameValueFmt) '    ', F_old(1,2), ','
    write(101, nameValueFmt) '    ', F_old(2,3), ','
    write(101, nameValueFmt) '    ', F_old(3,1), ','
    write(101, nameValueFmt) '    ', F_old(2,1), ','
    write(101, nameValueFmt) '    ', F_old(3,2), ','
    write(101, nameValueFmt) '    ', F_old(1,3), ','
    write(101, "(A)") ']'
    write(101, "(A,E21.15E2)") 'DT = ', DT
    write(101, "(A,I1,A)") 'ndir = ', ndir
    write(101, "(A,I1,A)") 'nshr = ', nshr

    close(101)
#endif
    Return
  End Subroutine writeDGDArgsToFile

#ifdef PYEXT
  Subroutine log_init(level, fileName)

    Use forlog_Mod

    ! Arguments
    Integer, intent(IN) :: level
    Character(*), intent(IN) :: fileName

    log%fileUnit = 107
    log%level = level

    open(log%fileUnit, file=trim(fileName), status='replace', recl=1000)
  End Subroutine log_init

  Subroutine log_close()
    Use forlog_Mod
    close(log%fileUnit)
  End Subroutine log_close

#endif

End Module DGD_Mod
